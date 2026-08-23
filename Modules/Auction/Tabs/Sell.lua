local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");
--Vendor prices without touching the auction slot. The slot only knows what is
--in it, and nothing is in it until the moment of posting any more.
local LIP = LibStub and LibStub:GetLibrary("ItemPrice-1.1", true);

--Cache global variables
--Lua functions
local tonumber, tostring, unpack = tonumber, tostring, unpack
local format, find, sub, lower = string.format, string.find, string.sub, string.lower
local getn, tinsert = table.getn, table.insert
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
--WoW API / Variables
local GetTime = GetTime
local CreateFrame = CreateFrame
local GetContainerNumSlots = GetContainerNumSlots
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetAuctionSellItemInfo = GetAuctionSellItemInfo
local ClickAuctionSellItemButton = ClickAuctionSellItemButton
local PickupContainerItem = PickupContainerItem
local SplitContainerItem = SplitContainerItem
local ClearCursor = ClearCursor
local CursorHasItem = CursorHasItem
local StartAuction = StartAuction
local UnitFactionGroup = UnitFactionGroup
local GameTooltip = GameTooltip
local UnitName = UnitName

--[[
	The Sell tab: put an item up, priced a copper under the market.

	EVERY PRICE HERE IS PER UNIT, and the total is arithmetic on the stack. That is
	not a presentation choice, it is what the client wants: StartAuction takes the
	price for the WHOLE stack, so a per-unit figure has to be multiplied by the
	quantity actually in the auction slot before it is sent. Getting that backwards
	posts a 20-stack for the price of one item, which is a gift to whoever is
	watching and cannot be undone.

	IT CHECKS THE LIVE MARKET WHEN YOU PICK AN ITEM. Selecting something starts a
	quiet scan for that exact name and the Post button goes dark and says so until
	it finishes -- an undercut is only worth anything against what is on the auction
	house NOW, and posting against a reading from last Tuesday is worse than not
	undercutting at all. The stored database is the fallback for when there is no
	session to scan in, and its age is shown so a stale figure is visibly stale.

	YOUR OWN AUCTIONS ARE EXCLUDED from that figure. Undercutting yourself by a
	copper every time you repost is a loop that ends with your own goods at one
	copper, and it is not obvious it is happening until the gold is gone.

	IT POSTS ONE STACK AT A TIME AND WAITS. StartAuction is fire and forget with no
	return value, so the only evidence it worked is the auction slot emptying. A loop
	that posted without waiting would race the server, and the failure mode is
	duplicate or missing auctions with real gold attached.

	STACK SIZES COME FROM WHAT IS IN THE BAGS. A requested size is taken by splitting
	a single bag stack that already holds at least that many. Building a bigger stack
	by merging several is deliberately not done -- it shuffles the player's bags
	around to do it, and the failure modes of that belong to their own change.
]]

local DURATIONS = {
	{minutes = 120, label = L["2h"]},
	{minutes = 480, label = L["8h"]},
	{minutes = 1440, label = L["24h"]}
}

--Short, because these are local client operations that either happen within a frame
--or two or are not going to. Three seconds a stage with three retries meant a single
--stuck step cost nine seconds and a run of five stacks felt broken long before it
--reported anything.
local POST_TIMEOUT = 5      --seconds to wait for the server to confirm one auction
local PLACE_TIMEOUT = 1     --seconds to wait for an item to move

local sell = {duration = 2}

--What each step of a post is called, for the progress bar. A run that stalls should
--say which of four things it was doing, not just how many auctions it managed.
local STAGE_LABEL = {
	["clear"] = L["clearing the slot"],
	["resize"] = L["splitting the stack"],
	["pick"] = L["picking it up"],
	["drop"] = L["placing it"],
	["posting"] = L["waiting for the auction house"]
}

--------------------------------------------------------------------------------
-- Bags
--------------------------------------------------------------------------------

--The name out of an item link, which is the only identifier a bag slot and an
--auction row genuinely share.
local function LinkName(link)
	if not link then return nil end
	local open, close = find(link, "%["), find(link, "%]")
	if not (open and close) then return nil end
	return sub(link, open + 1, close - 1)
end

--Every bag slot holding this item, with its stack size and whether the client has
--it locked. A locked slot is mid-move and must not be touched.
local function FindStacks(name)
	local found = {}
	if not name then return found end

	for bag = 0, 4 do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			if LinkName(GetContainerItemLink(bag, slot)) == name then
				local _, count, locked = GetContainerItemInfo(bag, slot)
				tinsert(found, {bag = bag, slot = slot, count = count or 1, locked = locked})
			end
		end
	end

	return found
end

local function LargestStack(name)
	local biggest, total = 0, 0

	local stacks = FindStacks(name)
	for i = 1, getn(stacks) do
		total = total + stacks[i].count
		if stacks[i].count > biggest then biggest = stacks[i].count end
	end

	return biggest, total
end

--A slot holding at least `size`, preferring an exact match so a whole stack is
--picked up rather than split when it does not need to be. With `exactOnly` it returns
--nothing unless a slot holds precisely that many, which is the question the resize
--stage asks: "is there a stack I can post as it stands yet".
local function StackFor(name, size, exactOnly)
	local stacks = FindStacks(name)
	local fallback

	for i = 1, getn(stacks) do
		local entry = stacks[i]
		if not entry.locked and entry.count >= size then
			if entry.count == size then return entry end
			if not fallback then fallback = entry end
		end
	end

	if exactOnly then return nil end
	return fallback
end

--------------------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------------------

--What the market is charging per unit, and how old that reading is.
local function MarketPrice(name)
	if not (name and E.global and E.global.auctionPrices) then return nil end

	local record = E.global.auctionPrices[name]
	if not record then return nil end

	local unit = record.unitBuyout
	if not unit or unit <= 0 then return nil end

	return unit, record.when
end

--[[
	The cheapest per-unit buyout in a set of scanned rows, ignoring your own.

	Ignoring your own is the part that matters. Undercut yourself once and the next
	repost undercuts that, and the one after undercuts THAT -- a ratchet that walks
	your own goods down to a copper while looking like it is working correctly.
]]
local function CheapestFrom(results)
	local player = UnitName and UnitName("player")
	local cheapest

	for i = 1, getn(results or {}) do
		local entry = results[i]
		if entry.unitBuyout and entry.unitBuyout > 0 and entry.owner ~= player then
			if not cheapest or entry.unitBuyout < cheapest then cheapest = entry.unitBuyout end
		end
	end

	return cheapest
end

--[[
	A copper under the cheapest, per unit.

	Undercutting per unit rather than per stack is the whole point: a buyer sorts on
	what an item costs, and a stack priced one copper under a rival STACK can still
	be dearer per item than theirs. Ceil first so a fractional market price never
	rounds down into a price the auction house will not accept.

	Never below one copper. StartAuction refuses a zero bid, and an item genuinely
	worth nothing is one to vendor rather than list.
]]
local function Undercut(unitPrice)
	if not unitPrice or unitPrice <= 1 then return 1 end
	return max(1, ceil(unitPrice) - 1)
end

--Deposit, computed rather than asked for. CalculateAuctionDeposit is not present
--on every build of this client and a working auction addon on it does the same
--arithmetic instead: a fraction of the vendor price, scaled by stack and duration.
--UnitFactionGroup("npc") is false at a neutral auctioneer, where the cut is five
--times higher.
local function Deposit(vendorUnit, stackSize, stackCount, minutes)
	if not (vendorUnit and vendorUnit > 0) then return 0 end

	local factor = UnitFactionGroup and UnitFactionGroup("npc") and 0.05 or 0.25
	local durationFactor = (minutes or 120) / 120

	return floor(vendorUnit * factor * stackSize) * stackCount * durationFactor
end

--------------------------------------------------------------------------------
-- Money entry
--------------------------------------------------------------------------------

--Gold, silver and copper as three numeric boxes, which is how the client's own
--auction house asks for a price and therefore what people expect.
local function MoneyInput(parent, label, anchor, xOffset, onChange)
	local box = {}

	local heading = parent:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(heading, nil, 9, "NONE")
	heading:SetTextColor(0.6, 0.6, 0.6)

	local previous
	local fields = {
		{key = "gold", width = 46, suffix = L["goldabbrev"]},
		{key = "silver", width = 28, suffix = L["silverabbrev"]},
		{key = "copper", width = 28, suffix = L["copperabbrev"]}
	}

	for i = 1, getn(fields) do
		local field = fields[i]
		local edit = CreateFrame("EditBox", nil, parent)
		E:Size(edit, field.width, 18)
		E:SetTemplate(edit, "Transparent")
		edit:SetAutoFocus(false)
		edit:SetNumeric(true)
		edit:SetTextInsets(3, 3, 0, 0)
		E:FontTemplate(edit, nil, 11, "NONE")
		edit:SetScript("OnEscapePressed", function() this:ClearFocus() end)
		edit:SetScript("OnTextChanged", function() if onChange then onChange() end end)

		if previous then
			E:Point(edit, "LEFT", previous, "RIGHT", 12, 0)
		else
			E:Point(edit, "LEFT", anchor, "RIGHT", xOffset, 0)
		end

		local suffix = parent:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(suffix, nil, 10, "NONE")
		E:Point(suffix, "LEFT", edit, "RIGHT", 1, 0)
		suffix:SetText(field.suffix)

		box[field.key] = edit
		previous = edit
	end

	E:Point(heading, "BOTTOMLEFT", box.gold, "TOPLEFT", 0, 1)
	heading:SetText(label)

	box.last = previous

	function box:Get()
		local g = tonumber(self.gold:GetText()) or 0
		local s = tonumber(self.silver:GetText()) or 0
		local c = tonumber(self.copper:GetText()) or 0
		return (g * 10000) + (s * 100) + c
	end

	function box:Set(copper)
		copper = copper or 0
		self.gold:SetText(tostring(floor(copper / 10000)))
		self.silver:SetText(tostring(floor(copper / 100) - (floor(copper / 10000) * 100)))
		self.copper:SetText(tostring(copper - (floor(copper / 100) * 100)))
	end

	return box
end

--------------------------------------------------------------------------------
-- Posting
--------------------------------------------------------------------------------

local pump

local function Pump()
	if not pump then pump = CreateFrame("Frame") end
	return pump
end

--[[
	The confirmation listener, registered only while one post is in flight.

	It listens for ERR_AUCTION_STARTED -- the "Auction created." line -- and that is
	the ONLY thing that means an auction exists. Two earlier attempts got this wrong in
	opposite directions:

	  * A PERMANENT listener double-counted. A chat message carries no identity, so one
	    arriving late was credited to whichever post happened to be in flight.
	  * The auction slot emptying is not proof of anything. The client clears the slot
	    the moment StartAuction is called, whether or not the server accepts, so three
	    attempts that produced one auction were counted as three.

	Registered immediately before StartAuction and unregistered the instant a message
	matches, so the window it can hear anything in is exactly one post.

	Waiting for it also PACES the run, which is the other half of why this matters.
	Confirming on the emptied slot let the next StartAuction fire a frame later, and
	posting that fast is what the server was refusing.
]]
local confirm

local function ConfirmFrame()
	if not confirm then confirm = CreateFrame("Frame") end
	return confirm
end

local function StopListening()
	if confirm then confirm:UnregisterEvent("CHAT_MSG_SYSTEM") end
end

local function StopPosting(message)
	sell.posting = false
	StopListening()
	if pump then pump:SetScript("OnUpdate", nil) end

	if sell.OnPostFinished then sell.OnPostFinished(message) end
end

--[[
	Getting one stack of exactly `size` into the auction slot.

	THE SPLIT HAPPENS IN THE BAGS, NOT INTO THE AUCTION SLOT. The obvious approach --
	SplitContainerItem to put `size` on the cursor, then click the auction slot -- does
	not work. The pickup is audible and nothing arrives. A working auction addon on this
	client never does that either: it resizes a stack in the BAGS until one slot holds
	exactly the number wanted, and only then picks that whole slot up and drops it in.
	SplitContainerItem is paired with PickupContainerItem on a BAG SLOT, always.

	So: split `size` off the big stack into an empty bag slot, and that slot becomes the
	thing that gets posted. It needs a free bag slot, which is a real requirement rather
	than an edge case, and is worth saying plainly when there is not one.

	EVERY STEP WAITS. Moving an item locks the bag slot until the server acknowledges,
	and a split against a locked slot does nothing and reports nothing. Each stage has
	its own evidence that it worked before the next is issued:

	    resize -> a bag slot holds exactly `size` of this item
	    clear  -> the auction slot reads empty
	    pick   -> the cursor is holding something
	    drop   -> the auction slot holds this item at this stack size
]]
local PLACE_RETRIES = 3

local function BeginStage(stage, timeout)
	--Shown live. A run that stalls used to report only a total at the end, which said
	--nothing about which of four steps it died in.
	if sell.OnPostStage then sell.OnPostStage(stage) end

	sell.stage = stage
	sell.issued = false
	sell.tries = 0
	sell.deadline = GetTime() + (timeout or PLACE_TIMEOUT)
end

--True when the step should give up. Re-arms for another attempt while tries remain,
--because a locked bag slot is a timing accident rather than a failure.
local function StageExpired()
	if GetTime() <= sell.deadline then return false end

	if sell.tries < PLACE_RETRIES then
		sell.tries = sell.tries + 1
		sell.issued = false
		sell.deadline = GetTime() + PLACE_TIMEOUT
		return false
	end

	return true
end

--The auction slot holds what we meant to put there. Checked rather than assumed,
--because the next thing that happens spends gold on whatever is in that slot.
local function SlotReady(name, size)
	local slotName, _, slotCount = GetAuctionSellItemInfo()
	return slotName == name and (slotCount or 0) == size
end

local function BagSlotHolds(bag, slot, name, count)
	if LinkName(GetContainerItemLink(bag, slot)) ~= name then return false end
	local _, slotCount = GetContainerItemInfo(bag, slot)
	return (slotCount or 0) == count
end

--A free bag slot to split into. The backpack comes first because it is always a
--general-purpose bag; a quiver or a soul bag has empty slots that will not take an
--ore, and the move into one silently does nothing.
local function FindEmptySlot()
	for bag = 0, 4 do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			if not GetContainerItemLink(bag, slot) then
				return {bag = bag, slot = slot}
			end
		end
	end
end

local function PostNext()
	if sell.posted >= sell.count then
		StopPosting(format(L["AUCTION_POST_DONE"], sell.posted))
		return
	end

	--Already holding exactly what we want, which is the ordinary case for posting a
	--whole stack. Nothing to move.
	if SlotReady(sell.name, sell.size) then
		BeginStage("drop")
		return
	end

	sell.target = nil

	--CLEAR FIRST. Anything sitting in the auction slot is invisible to the bag search,
	--so resizing before emptying looks for a stack that is standing right there in the
	--window and concludes there are none left.
	BeginStage("clear")
end

--[[
	One auction went up.

	THE EMPTY SLOT IS THE ONLY SIGNAL, and it used not to be. ERR_AUCTION_STARTED on
	CHAT_MSG_SYSTEM was accepted as a second confirmation, on the reasoning that two
	routes are safer than one. They are not, because a chat message carries no identity
	and can arrive late: the slot emptying confirmed the first auction, the run moved on
	and began the second, and then the FIRST auction's message turned up and was counted
	against the second. One auction posted, the counter said two, and the post actually
	in flight was abandoned where it stood.

	The slot is unambiguous by construction. While a post is in flight the slot holds
	that post's item -- it was verified to one stage earlier -- so an empty slot can only
	mean the server took THIS one. A rejected post leaves the item sitting there and
	times out, which is exactly right.
]]
local function Confirmed()
	if sell.stage ~= "posting" then return end
	sell.stage = "confirmed"

	sell.posted = sell.posted + 1
	if sell.OnPostProgress then sell.OnPostProgress(sell.posted, sell.count) end

	PostNext()
end

local function OnUpdate()
	if not sell.posting then
		this:SetScript("OnUpdate", nil)
		return
	end

	if sell.stage == "resize" then
		--A bag slot already holding exactly the right number is the target, whether it
		--was always that size or the split just made it one.
		local exact = StackFor(sell.name, sell.size, true)
		if exact then
			sell.target = exact
			BeginStage("pick")
			return
		end

		if not sell.issued then
			local source = StackFor(sell.name, sell.size)
			if not source then
				StopPosting(format(L["AUCTION_POST_OUT_OF_STOCK"], sell.posted))
				return
			end

			local empty = FindEmptySlot()
			if not empty then
				StopPosting(L["AUCTION_POST_NO_BAG_SPACE"])
				return
			end

			sell.issued = true
			ClearCursor()
			SplitContainerItem(source.bag, source.slot, sell.size)
			PickupContainerItem(empty.bag, empty.slot)
		elseif StageExpired() then
			ClearCursor()
			StopPosting(format(L["AUCTION_POST_SPLIT_FAILED"], sell.posted))
		end

	elseif sell.stage == "clear" then
		if not GetAuctionSellItemInfo() then
			BeginStage("resize")
		elseif not sell.issued then
			sell.issued = true
			ClearCursor()
			ClickAuctionSellItemButton()
			ClearCursor()
		elseif StageExpired() then
			StopPosting(format(L["AUCTION_POST_SLOT_FAILED"], sell.posted))
		end

	elseif sell.stage == "pick" then
		if CursorHasItem() then
			BeginStage("drop")
		elseif not sell.issued then
			--Re-checked rather than trusted: emptying the auction slot puts an item back
			--in the bags and can move things around underneath us.
			local target = sell.target
			if not (target and BagSlotHolds(target.bag, target.slot, sell.name, sell.size)) then
				target = StackFor(sell.name, sell.size, true)
				sell.target = target
			end

			if not target then
				BeginStage("resize")
				return
			end

			sell.issued = true
			ClearCursor()
			PickupContainerItem(target.bag, target.slot)
		elseif StageExpired() then
			ClearCursor()
			StopPosting(format(L["AUCTION_POST_SLOT_FAILED"], sell.posted))
		end

	elseif sell.stage == "drop" then
		if SlotReady(sell.name, sell.size) then
			ClearCursor()

			--Per unit times the quantity in the slot. The bid is floored at one copper
			--because StartAuction refuses a zero.
			local bid = max(1, sell.unitBid * sell.size)
			local buyout = sell.unitBuyout > 0 and (sell.unitBuyout * sell.size) or 0

			BeginStage("posting", POST_TIMEOUT)

			--Armed BEFORE the call, so a fast server cannot answer before anything is
			--listening.
			ConfirmFrame():RegisterEvent("CHAT_MSG_SYSTEM")
			StartAuction(bid, buyout, sell.minutes)
		elseif not sell.issued then
			sell.issued = true
			ClickAuctionSellItemButton()
			ClearCursor()
		elseif GetTime() > sell.deadline then
			--No retry here. Clicking the slot again with an empty cursor takes the item
			--back OUT of it, so a retry of this particular step undoes the placement it
			--is meant to be repeating.
			ClearCursor()
			StopPosting(format(L["AUCTION_POST_SLOT_FAILED"], sell.posted))
		end

	elseif sell.stage == "posting" then
		--Nothing to poll. The listener confirms it, or this times out.
		if GetTime() > sell.deadline then
			StopPosting(format(L["AUCTION_POST_NO_CONFIRM"], sell.posted))
		end
	end
end

--Set up once. The frame only has the event registered while a post is in flight, so
--this cannot hear anything outside that window.
ConfirmFrame():SetScript("OnEvent", function()
	if sell.stage ~= "posting" then return end
	if not (ERR_AUCTION_STARTED and arg1 == ERR_AUCTION_STARTED) then return end

	StopListening()
	Confirmed()
end)

function A:PostAuctions(name, size, count, unitBid, unitBuyout, minutes)
	if sell.posting then return false end

	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	sell.name = name
	sell.size = size
	sell.count = count
	sell.unitBid = unitBid
	sell.unitBuyout = unitBuyout
	sell.minutes = minutes
	sell.posted = 0
	sell.posting = true

	Pump():SetScript("OnUpdate", OnUpdate)
	PostNext()

	return true
end

function A:IsPosting()
	return sell.posting and true or false
end

function A:CancelPosting()
	if sell.posting then StopPosting(format(L["AUCTION_POST_STOPPED"], sell.posted)) end
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

A.tabBuilders = A.tabBuilders or {}

A.tabBuilders["post"] = function(page)
	local selected = {}

	local icon = CreateFrame("Button", nil, page)
	E:Size(icon, 32, 32)
	E:SetTemplate(icon, "Transparent")
	E:Point(icon, "TOPLEFT", page, "TOPLEFT", 0, 0)
	icon.texture = icon:CreateTexture(nil, "ARTWORK")
	E:SetInside(icon.texture, icon, 2, 2)
	if E.db.general.cropIcon then icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92) end

	local itemName = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(itemName, nil, 12, "NONE")
	E:Point(itemName, "LEFT", icon, "RIGHT", 8, 6)
	itemName:SetText(L["AUCTION_SELL_PICK_ITEM"])
	itemName:SetTextColor(0.6, 0.6, 0.6)

	local stockText = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(stockText, nil, 10, "NONE")
	E:Point(stockText, "TOPLEFT", itemName, "BOTTOMLEFT", 0, -3)
	stockText:SetTextColor(0.6, 0.6, 0.6)

	--Row: stack size and how many of them
	local sizeLabel = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(sizeLabel, nil, 10, "NONE")
	E:Point(sizeLabel, "TOPLEFT", page, "TOPLEFT", 0, -46)
	sizeLabel:SetText(L["Stack size"])
	sizeLabel:SetTextColor(0.8, 0.8, 0.8)

	local sizeBox = CreateFrame("EditBox", nil, page)
	E:Size(sizeBox, 40, 18)
	E:SetTemplate(sizeBox, "Transparent")
	E:Point(sizeBox, "LEFT", sizeLabel, "RIGHT", 8, 0)
	sizeBox:SetAutoFocus(false)
	sizeBox:SetNumeric(true)
	sizeBox:SetTextInsets(3, 3, 0, 0)
	E:FontTemplate(sizeBox, nil, 11, "NONE")
	sizeBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

	local countLabel = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(countLabel, nil, 10, "NONE")
	E:Point(countLabel, "LEFT", sizeBox, "RIGHT", 16, 0)
	countLabel:SetText(L["Stacks"])
	countLabel:SetTextColor(0.8, 0.8, 0.8)

	local countBox = CreateFrame("EditBox", nil, page)
	E:Size(countBox, 40, 18)
	E:SetTemplate(countBox, "Transparent")
	E:Point(countBox, "LEFT", countLabel, "RIGHT", 8, 0)
	countBox:SetAutoFocus(false)
	countBox:SetNumeric(true)
	countBox:SetTextInsets(3, 3, 0, 0)
	E:FontTemplate(countBox, nil, 11, "NONE")
	countBox:SetText("1")
	countBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

	--Duration
	local durationLabel = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(durationLabel, nil, 10, "NONE")
	E:Point(durationLabel, "LEFT", countBox, "RIGHT", 20, 0)
	durationLabel:SetText(L["Duration"])
	durationLabel:SetTextColor(0.8, 0.8, 0.8)

	local durationButtons = {}
	local previous
	for i = 1, getn(DURATIONS) do
		local button = CreateFrame("Button", nil, page)
		E:Size(button, 38, 18)
		E:SetTemplate(button, "Transparent")
		if previous then
			E:Point(button, "LEFT", previous, "RIGHT", 3, 0)
		else
			E:Point(button, "LEFT", durationLabel, "RIGHT", 8, 0)
		end
		button.text = button:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(button.text, nil, 10, "NONE")
		button.text:SetAllPoints()
		button.text:SetText(DURATIONS[i].label)
		button.index = i
		durationButtons[i] = button
		previous = button
	end

	--Forward declarations. Each of these is referenced by a closure defined before
	--the one that fills it in, and a local declared later would leave those reading
	--a nil global instead.
	local Refresh, ApplyUndercut, CheckPrices, RefreshStock

	local function SelectDuration(index)
		sell.duration = index
		for i = 1, getn(durationButtons) do
			if i == index then
				durationButtons[i]:SetBackdropBorderColor(unpack(E.media.rgbvaluecolor))
				durationButtons[i].text:SetTextColor(unpack(E.media.rgbvaluecolor))
			else
				E:SetTemplate(durationButtons[i], "Transparent")
				durationButtons[i].text:SetTextColor(0.8, 0.8, 0.8)
			end
		end
		Refresh()
	end

	for i = 1, getn(durationButtons) do
		durationButtons[i]:SetScript("OnClick", function() SelectDuration(this.index) end)
	end

	--Prices, per unit
	local bidAnchor = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(bidAnchor, nil, 10, "NONE")
	E:Point(bidAnchor, "TOPLEFT", page, "TOPLEFT", 0, -92)
	bidAnchor:SetText(L["Bid/ea"])
	bidAnchor:SetTextColor(0.8, 0.8, 0.8)

	local bidBox = MoneyInput(page, "", bidAnchor, 8, function() Refresh() end)

	local buyoutAnchor = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(buyoutAnchor, nil, 10, "NONE")
	E:Point(buyoutAnchor, "LEFT", bidBox.last, "RIGHT", 26, 0)
	buyoutAnchor:SetText(L["Buyout/ea"])
	buyoutAnchor:SetTextColor(0.8, 0.8, 0.8)

	local buyoutBox = MoneyInput(page, "", buyoutAnchor, 8, function() Refresh() end)

	local undercutButton = CreateFrame("Button", nil, page)
	E:Size(undercutButton, 80, 18)
	E:SetTemplate(undercutButton, "Transparent")
	E:Point(undercutButton, "LEFT", buyoutBox.last, "RIGHT", 26, 0)
	undercutButton.text = undercutButton:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(undercutButton.text, nil, 11, "NONE")
	undercutButton.text:SetAllPoints()
	undercutButton.text:SetText(L["Undercut"])

	local checkButton = CreateFrame("Button", nil, page)
	E:Size(checkButton, 80, 18)
	E:SetTemplate(checkButton, "Transparent")
	E:Point(checkButton, "LEFT", undercutButton, "RIGHT", 6, 0)
	checkButton.text = checkButton:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(checkButton.text, nil, 11, "NONE")
	checkButton.text:SetAllPoints()
	checkButton.text:SetText(L["Check now"])

	--Summary and action
	local summary = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(summary, nil, 11, "NONE")
	E:Point(summary, "TOPLEFT", page, "TOPLEFT", 0, -128)
	summary:SetJustifyH("LEFT")
	summary:SetTextColor(0.85, 0.85, 0.85)

	local priceSource = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(priceSource, nil, 10, "NONE")
	E:Point(priceSource, "TOPLEFT", summary, "BOTTOMLEFT", 0, -6)
	priceSource:SetJustifyH("LEFT")
	priceSource:SetTextColor(0.6, 0.6, 0.6)

	local postButton = CreateFrame("Button", nil, page)
	E:Size(postButton, 120, 22)
	E:SetTemplate(postButton, "Transparent")
	E:Point(postButton, "TOPLEFT", priceSource, "BOTTOMLEFT", 0, -12)
	postButton.text = postButton:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(postButton.text, nil, 12, "NONE")
	postButton.text:SetAllPoints()
	postButton.text:SetText(L["Post"])

	--------------------------------------------------------------------------
	-- Behaviour
	--------------------------------------------------------------------------

	local function StackSize()
		local size = tonumber(sizeBox:GetText()) or 1
		if size < 1 then size = 1 end
		if selected.largest and size > selected.largest then size = selected.largest end
		return size
	end

	local function StackCount()
		local count = tonumber(countBox:GetText()) or 1
		if count < 1 then count = 1 end

		--Never offer to post more than the bags can actually supply. The posting
		--loop stops cleanly when it runs out, but a summary promising nine stacks
		--from six stacks' worth of items is a lie before a single copper is spent.
		local size = StackSize()
		if selected.total and size > 0 then
			local possible = floor(selected.total / size)
			if possible < 1 then possible = 1 end
			if count > possible then count = possible end
		end

		return count
	end

	Refresh = function()
		if not selected.name then
			summary:SetText("")
			priceSource:SetText("")
			return
		end

		local size, count = StackSize(), StackCount()
		local unitBid, unitBuyout = bidBox:Get(), buyoutBox:Get()
		local minutes = DURATIONS[sell.duration].minutes
		local deposit = Deposit(selected.vendor, size, count, minutes)

		summary:SetText(format(L["AUCTION_SELL_SUMMARY"],
			count, size, selected.name,
			A:Money(unitBuyout * size), A:Money(unitBid * size)))

		local depositText = format(L["AUCTION_SELL_DEPOSIT"], A:Money(deposit))

		if selected.competing == 0 then
			priceSource:SetText(depositText.."   "..L["AUCTION_SELL_NO_COMPETITION"])
		elseif selected.marketWhen then
			priceSource:SetText(depositText.."   "..format(L["AUCTION_SELL_SOURCE"],
				A:Money(selected.market), A:PriceAge(selected.marketWhen)))
		else
			priceSource:SetText(depositText.."   "..L["AUCTION_SELL_NO_DATA"])
		end
	end

	--[[
		The bag figures changed and nothing else did.

		Deliberately NOT a full Select. Select re-runs the price check and resets the
		stack size box to whatever the bags happen to hold, and calling it after a post
		meant a second scan nobody asked for and a stack size silently thrown away right
		before the player posted the next one. The market was checked when the item was
		picked; posting does not change it.
	]]
	RefreshStock = function()
		if not selected.name then return end

		local largest, total = LargestStack(selected.name)
		selected.largest = largest
		selected.total = total
		stockText:SetText(format(L["AUCTION_SELL_STOCK"], total, largest))

		Refresh()
	end

	ApplyUndercut = function()
		if not selected.name then return end

		if not selected.market then
			E:Print(format(L["AUCTION_SELL_NEVER_SCANNED"], selected.name))
			return
		end

		local price = Undercut(selected.market)
		buyoutBox:Set(price)
		--Bid matched to buyout by default. A lower opening bid only helps somebody
		--win the item for less than it is worth, and anyone who wants that can type
		--it in.
		bidBox:Set(price)
		Refresh()
	end

	--[[
		The Post button doubles as the status of the price check.

		Greying it is not decoration: between picking an item and the scan coming
		back, the prices in the boxes are the OLD market, and posting then is exactly
		the mistake the check exists to prevent. Naming the state on the button is
		what makes the wait legible rather than a frozen-looking window.
	]]
	local function SetPostState(state)
		if state == "checking" then
			postButton:Disable()
			postButton.text:SetText(L["AUCTION_SELL_CHECKING"])
			postButton.text:SetTextColor(0.5, 0.5, 0.5)
		elseif state == "posting" then
			postButton:Enable()
			postButton.text:SetText(L["Cancel"])
			postButton.text:SetTextColor(1, 1, 1)
		else
			postButton:Enable()
			postButton.text:SetText(L["Post"])
			postButton.text:SetTextColor(1, 1, 1)
		end
	end

	--[[
		Scan this one item, quietly, and reprice from what comes back.

		Its own handlers, so nothing here touches the Search tab's list or buttons.
		The scan is by name, which the server matches as a substring, so the results
		are filtered to the exact item before the cheapest is taken -- otherwise a
		Solid Stone would be priced against Solid Sharpening Stone.
	]]
	CheckPrices = function(name)
		if not (name and A:AtAuctionHouse()) then return false end
		if A:IsScanning() or A:IsPosting() then return false end

		local handlers = {}

		handlers.progress = function(pageNumber, collected, total, totalPages)
			A:SetProgress(pageNumber, totalPages,
				format(L["AUCTION_SELL_CHECKING_PAGE"], name, pageNumber, totalPages or 0))
		end

		handlers.complete = function(results)
			A:HideProgress()
			SetPostState("idle")

			local exact = {}
			for i = 1, getn(results or {}) do
				if results[i].name == name then tinsert(exact, results[i]) end
			end

			local cheapest = CheapestFrom(exact)

			if cheapest then
				selected.market = cheapest
				selected.marketWhen = time()
				selected.competing = getn(exact)
				ApplyUndercut()
			else
				--Nobody else is selling it. There is nothing to undercut, so the
				--stored figure stays and the summary says why.
				selected.competing = 0
				Refresh()
			end
		end

		if A:StartScan(name, nil, nil, handlers) then
			SetPostState("checking")
			A:SetProgress(0, nil, format(L["AUCTION_SELL_CHECKING_START"], name))
			return true
		end

		return false
	end

	local function Select(name, itemID, texture)
		selected.name = name
		if itemID then selected.id = itemID end
		if texture then selected.texture = texture end

		if not name then
			selected.texture = nil
			selected.vendor = nil
			selected.id = nil
			icon.texture:SetTexture(nil)
			itemName:SetText(L["AUCTION_SELL_PICK_ITEM"])
			itemName:SetTextColor(0.6, 0.6, 0.6)
			stockText:SetText("")
			Refresh()
			return
		end

		local largest, total = LargestStack(name)
		selected.largest = largest
		selected.total = total
		selected.market, selected.marketWhen = MarketPrice(name)

		--The deposit is a fraction of the vendor price PER UNIT. That used to be read
		--from the auction slot, which meant the item had to be sitting in it -- and an
		--item in the auction slot is invisible to the bag search, which is what made
		--posting report "ran out of items" with a full stack in hand. LibItemPrice
		--answers the same question from an id, with nothing moved anywhere.
		if selected.id and LIP then
			selected.vendor = LIP:GetSellValue(selected.id)
		end

		icon.texture:SetTexture(selected.texture)

		itemName:SetText(name)
		itemName:SetTextColor(1, 1, 1)
		stockText:SetText(format(L["AUCTION_SELL_STOCK"], total, largest))

		sizeBox:SetText(tostring(largest > 0 and largest or 1))
		countBox:SetText("1")
		selected.competing = nil

		--The stored figure goes in immediately so the boxes are never blank, then the
		--live check overwrites it. If there is no session to scan in, the stored one
		--is all there is and the summary says how old it is.
		if selected.market then ApplyUndercut() else Refresh() end

		if not CheckPrices(name) then SetPostState("idle") end
	end

	E.PopupDialogs["OCTOUI_AUCTION_POST"] = {
		text = L["AUCTION_SELL_CONFIRM"],
		button1 = ACCEPT,
		button2 = CANCEL,
		OnAccept = function()
			local pending = A.pendingPost
			A.pendingPost = nil
			if not pending then return end

			A:PostAuctions(pending.name, pending.size, pending.count,
				pending.unitBid, pending.unitBuyout, pending.minutes)
		end,
		OnCancel = function() A.pendingPost = nil end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1
	}

	local function Post()
		if A:IsPosting() then
			A:CancelPosting()
			return
		end

		if not selected.name then
			E:Print(L["AUCTION_SELL_PICK_ITEM"])
			return
		end

		local size, count = StackSize(), StackCount()
		local unitBid, unitBuyout = bidBox:Get(), buyoutBox:Get()

		if unitBid <= 0 and unitBuyout <= 0 then
			E:Print(L["AUCTION_SELL_NEEDS_PRICE"])
			return
		end

		--A buyout under the opening bid is refused by the server, and the error it
		--gives is not obviously about that. Catch it here where the fix is visible.
		if unitBuyout > 0 and unitBuyout < unitBid then
			E:Print(L["AUCTION_SELL_BUYOUT_BELOW_BID"])
			return
		end

		A.pendingPost = {
			name = selected.name,
			size = size,
			count = count,
			unitBid = max(1, unitBid),
			unitBuyout = unitBuyout,
			minutes = DURATIONS[sell.duration].minutes
		}

		E:StaticPopup_Show("OCTOUI_AUCTION_POST",
			format("%d x %s (%d)", count, selected.name, size),
			A:Money((unitBuyout > 0 and unitBuyout or unitBid) * size * count))
	end

	undercutButton:SetScript("OnClick", ApplyUndercut)
	undercutButton:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 1, 1) end)
	undercutButton:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)

	checkButton:SetScript("OnClick", function()
		if selected.name then CheckPrices(selected.name) end
	end)
	checkButton:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Check now"])
		GameTooltip:AddLine(L["AUCTION_SELL_CHECK_TIP"], 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	checkButton:SetScript("OnLeave", function()
		E:SetTemplate(this, "Transparent")
		GameTooltip:Hide()
	end)

	postButton:SetScript("OnClick", Post)
	postButton:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 1, 1) end)
	postButton:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)

	icon:SetScript("OnClick", function() Select(nil) end)

	sizeBox:SetScript("OnTextChanged", function() Refresh() end)
	countBox:SetScript("OnTextChanged", function() Refresh() end)

	sell.OnPostProgress = function(posted, total)
		SetPostState("posting")
		A:SetProgress(posted, total, format(L["AUCTION_POST_PROGRESS"], posted, total))
	end

	sell.OnPostStage = function(stage)
		if not A:IsPosting() then return end

		A:SetProgress(sell.posted, sell.count, format(L["AUCTION_POST_STAGE"],
			sell.posted + 1, sell.count, STAGE_LABEL[stage] or stage))
	end

	sell.OnPostFinished = function(message)
		SetPostState("idle")
		A:HideProgress()
		A:SetStatus(message or "")
		if message then E:Print(message) end
		--Bag contents changed underneath us, so the stack figures are stale. If the
		--last of it went up, drop the selection entirely rather than leaving an item on
		--screen that there is none of; otherwise only the counts are refreshed, leaving
		--the price and the stack size exactly as they were set.
		if selected.name then
			local _, remaining = LargestStack(selected.name)
			if remaining > 0 then RefreshStock() else Select(nil) end
		end
	end

--[[
		Reached from a right-click on a bag item while this tab is open.

		IT MOVES NOTHING. Selecting used to physically put the item in the auction slot,
		which reads as the obvious thing to do and quietly breaks everything after it: an
		item in that slot is not in the bags as far as GetContainerItemLink is concerned,
		so the posting code went looking for a stack to split and found none, and said
		the bags were empty while the item sat visibly in the window. A working auction
		addon on this client never fills the slot until the instant it posts, and neither
		does this now -- selection is a note of which item, nothing more.
	]]
	page.SelectItem = function(bag, slot)
		local link = GetContainerItemLink(bag, slot)
		local name = LinkName(link)
		if not name then return end

		local itemID
		if link then
			local _, _, id = find(link, "item:(%d+)")
			itemID = id and tonumber(id) or nil
		end

		local texture = GetContainerItemInfo(bag, slot)

		Select(name, itemID, texture)
	end

	SelectDuration(sell.duration)
	Select(nil)
end

--[[
	Put a bag item up for sale, from outside the tab.

	Selects the tab first, which also builds it: the player may never have opened
	Sell this session, and a right-click that silently did nothing would look
	exactly like the feature being missing.
]]
function A:SellFromBags(bag, slot)
	if not self.window then return false end

	self:SelectTab("post")

	local page = self.window.tabs and self.window.tabs["post"]
	if not (page and page.SelectItem) then return false end

	page.SelectItem(bag, slot)
	return true
end
