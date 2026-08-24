local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local format = string.format
local getn, tinsert = table.getn, table.insert
local floor = math.floor
--WoW API / Variables
local CreateFrame = CreateFrame
local GetNumAuctionItems = GetNumAuctionItems
local GetAuctionItemInfo = GetAuctionItemInfo
local GetAuctionItemTimeLeft = GetAuctionItemTimeLeft
local GetBidderAuctionItems = GetBidderAuctionItems
local PlaceAuctionBid = PlaceAuctionBid
local GetItemQualityColor = GetItemQualityColor
local GetTime = GetTime
local GameTooltip = GameTooltip

--[[
	The Bids tab: auctions you have bid on, and whether you are still winning.

	ANOTHER RESULT SET AGAIN. Your bids live in "bidder", fetched with
	GetBidderAuctionItems(page) and answered on AUCTION_BIDDER_LIST_UPDATE. Like the
	owner list it is NOT gated on CanSendAuctionQuery -- that gate is for the browse
	query alone -- and like the owner list it cannot be trusted to honour the page
	argument, so an identical page means there is no next one.

	highBidder MEANS SOMETHING DIFFERENT HERE. On the owner list it is the name of
	whoever is winning your auction. On this list it is a flag: set when YOU are the
	high bidder. Reading it as a name gives every row the same meaningless value and
	loses the one fact the tab exists to show.

	The next legal bid is bidAmount + minIncrement, or the opening bid where nobody
	has bid yet. The client will not accept less and says so unhelpfully, so it is
	computed here rather than left to the player to work out.

	SPENDING GOLD RE-READS FIRST, the same as buying and cancelling. PlaceAuctionBid
	takes an index into the list as the server last sent it, and that shifts as
	auctions sell and expire.
]]

local FETCH_TIMEOUT = 8
local GRACE = 0.4
local MAX_PAGES = 20

local bids = {results = {}}

local function BuildRow(index, page)
	local name, _, count, quality, _, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder =
		GetAuctionItemInfo("bidder", index)
	if not name then return nil end

	count = (count and count > 0) and count or 1
	minBid = minBid or 0
	bidAmount = bidAmount or 0
	local buyout = buyoutPrice or 0

	--Captured on arrival for the same reason as the Auctions tab: the index is into
	--the page the server last sent, and a hover happens long after that.
	local itemString, itemID = A:CaptureItem("bidder", index)

	return {
		name = name,
		count = count,
		quality = quality or 1,
		level = level,
		page = page,
		index = index,
		itemString = itemString,
		itemID = itemID,
		minBid = minBid,
		bid = bidAmount,
		buyout = buyout,
		--A flag on this list, not a name. Truthy means you are the high bidder.
		winning = highBidder and true or false,
		nextBid = (bidAmount > 0) and (bidAmount + (minIncrement or 0)) or minBid,
		unitBuyout = (buyout > 0) and floor((buyout / count) + 0.5) or 0,
		timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("bidder", index) or nil
	}
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

local pump

local function Stop()
	bids.active = false
	if pump then pump:SetScript("OnUpdate", nil) end
end

local function Finish(reason)
	Stop()
	if bids.onDone then bids.onDone(bids.results, reason) end
end

local function RequestPage(page)
	bids.page = page
	bids.awaiting = true
	bids.readAt = GetTime() + GRACE
	bids.deadline = GetTime() + FETCH_TIMEOUT
	GetBidderAuctionItems(page)
end

--Two pages that are identical are the server saying there is no next page. Paging
--on the reported total alone duplicates the whole list, which the Auctions tab
--demonstrated by growing a second Skullflame Shield.
local function PageSignature(batch)
	local parts = ""
	for i = 1, batch do
		local name, _, count, _, _, _, minBid, _, buyoutPrice, bidAmount = GetAuctionItemInfo("bidder", i)
		parts = parts..(name or "?")..":"..(count or 0)..":"..(minBid or 0)
			..":"..(buyoutPrice or 0)..":"..(bidAmount or 0)..";"
	end
	return parts
end

local function Consume()
	if not (bids.active and bids.awaiting) then return end
	bids.awaiting = false

	local batch, total = GetNumAuctionItems("bidder")
	batch = batch or 0
	bids.total = total or 0

	local signature = PageSignature(batch)
	if batch > 0 and signature == bids.lastSignature then
		Finish("done")
		return
	end
	bids.lastSignature = signature

	for i = 1, batch do
		local row = BuildRow(i, bids.page)
		if row then tinsert(bids.results, row) end
	end

	local collected = getn(bids.results)

	if batch == 0 or collected >= bids.total or (bids.page + 1) >= MAX_PAGES then
		Finish("done")
	else
		RequestPage(bids.page + 1)
	end
end

local function OnUpdate()
	if not bids.active then
		this:SetScript("OnUpdate", nil)
		return
	end

	if not bids.awaiting then return end

	--The event is an accelerator, not the trigger: asking again for a list the
	--client already holds can be answered with no event at all.
	if GetTime() >= bids.readAt then
		Consume()
	elseif GetTime() > bids.deadline then
		Finish("timeout")
	end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("AUCTION_BIDDER_LIST_UPDATE")
watcher:SetScript("OnEvent", function() Consume() end)

function A:FetchBids(onDone)
	if bids.active then return false end
	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	bids.results = {}
	bids.total = 0
	bids.lastSignature = nil
	bids.active = true
	bids.onDone = onDone

	if not pump then pump = CreateFrame("Frame") end
	pump:SetScript("OnUpdate", OnUpdate)

	RequestPage(0)
	return true
end

function A:IsFetchingBids()
	return bids.active and true or false
end

local function AbortFetch()
	Stop()
	bids.onDone = nil
end

--------------------------------------------------------------------------------
-- Bidding
--------------------------------------------------------------------------------

--Fields that cannot change under us. The live bid is excluded deliberately: it
--moves the moment anyone bids, which is precisely when re-finding the auction
--matters most.
local function Matches(entry, index)
	local name, _, count, _, _, _, minBid, _, buyoutPrice = GetAuctionItemInfo("bidder", index)
	if not name then return false end

	return name == entry.name
		and (count or 1) == entry.count
		and (buyoutPrice or 0) == entry.buyout
		and (minBid or 0) == entry.minBid
end

function A:PlaceBid(entry, amount, onDone)
	if self:IsFetchingBids() then AbortFetch() end

	self:FetchBids(function(results, reason)
		if reason ~= "done" then
			E:Print(L["AUCTION_BID_NO_LIST"])
			if onDone then onDone(false) end
			return
		end

		local batch = GetNumAuctionItems("bidder") or 0
		for i = 1, batch do
			if Matches(entry, i) then
				PlaceAuctionBid("bidder", i, amount)
				E:Print(format(L["AUCTION_BID_PLACED"], A:Money(amount), entry.name))
				if onDone then onDone(true) end
				return
			end
		end

		E:Print(L["AUCTION_BID_GONE"])
		if onDone then onDone(false) end
	end)
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

local ROWS = 19

local function QualityColor(entry)
	return GetItemQualityColor(entry.quality or 1)
end

--Money columns are wide on purpose; see the note in Tabs/Search.lua.
local COLUMNS = {
	{key = "name", label = L["Item"], width = 26, color = QualityColor},
	{key = "count", label = L["Qty"], width = 5, justify = "RIGHT"},
	{key = "bid", label = L["Your bid"], width = 17, justify = "RIGHT",
		format = function(v) return v > 0 and A:Money(v) or "|cff808080--|r" end},
	{key = "nextBid", label = L["Next bid"], width = 17, justify = "RIGHT",
		format = function(v) return v > 0 and A:Money(v) or "|cff808080--|r" end},
	{key = "buyout", label = L["Buyout"], width = 17, justify = "RIGHT",
		format = function(v) return v > 0 and A:Money(v) or "|cff808080--|r" end},
	{key = "timeLeft", label = L["Time"], width = 6, justify = "RIGHT",
		format = function(v)
			local text = {"30m", "2h", "8h", "24h"}
			return v and text[v] or ""
		end},
	{key = "winning", label = L["Status"], width = 12,
		--Sorts winning and losing apart rather than by the raw boolean, which Lua
		--will not compare at all.
		compare = function(a, b, descending)
			local av = a.winning and 1 or 0
			local bv = b.winning and 1 or 0
			if descending then return av > bv end
			return av < bv
		end,
		format = function(v)
			if v then return "|cff20ff20"..L["Winning"].."|r" end
			return "|cffff8000"..L["Outbid"].."|r"
		end}
}

A.tabBuilders = A.tabBuilders or {}

A.tabBuilders["bids"] = function(page)
	local refresh = CreateFrame("Button", nil, page)
	E:Size(refresh, 90, 18)
	E:SetTemplate(refresh, "Transparent")
	E:Point(refresh, "TOPLEFT", page, "TOPLEFT", 0, 0)
	refresh.text = refresh:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(refresh.text, nil, 11, "NONE")
	refresh.text:SetAllPoints()
	refresh.text:SetText(L["Refresh"])
	refresh:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 1, 1) end)
	refresh:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)

	local hint = page:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(hint, nil, 10, "NONE")
	E:Point(hint, "LEFT", refresh, "RIGHT", 10, 0)
	hint:SetText(L["AUCTION_BIDS_HINT"])
	hint:SetTextColor(0.6, 0.6, 0.6)

	local listing = A:CreateListing(page, COLUMNS, ROWS, 740)
	E:Point(listing, "TOPLEFT", page, "TOPLEFT", 0, -26)
	E:Point(listing, "BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	--Whatever is about to end comes first: that is the one still worth acting on.
	listing.sortColumn = 6
	listing.sortDescending = false

	page.listing = listing

	local function Load()
		if A:IsFetchingBids() then return end

		A:SetStatus(L["AUCTION_BIDS_LOADING"])

		A:FetchBids(function(results, reason)
			if reason == "timeout" then
				--Keep what is on screen. A failed refresh should not read as
				--"you have no bids".
				A:SetStatus(L["AUCTION_BIDS_TIMEOUT"])
				return
			end

			listing:SetData(results)
			A:SetStatus(format(L["AUCTION_BIDS_COUNT"], getn(results)))
		end)
	end

	refresh:SetScript("OnClick", Load)

	E.PopupDialogs["OCTOUI_AUCTION_BID"] = {
		text = L["AUCTION_BID_CONFIRM"],
		button1 = ACCEPT,
		button2 = CANCEL,
		OnAccept = function()
			local pending = A.pendingBid
			A.pendingBid = nil
			if pending then A:PlaceBid(pending.entry, pending.amount, function() Load() end) end
		end,
		OnCancel = function() A.pendingBid = nil end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1
	}

	listing.OnEnter = function(entry, row)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		--The item itself. Whether to raise a bid turns on what the thing is at least
		--as much as on what it currently costs.
		A:ItemTooltip(GameTooltip, entry)
		if entry.count > 1 then
			GameTooltip:AddLine(format(L["Stack of %d"], entry.count), 1, 1, 1)
		end

		if entry.winning then
			GameTooltip:AddLine(L["AUCTION_BID_YOU_LEAD"], 0.2, 1, 0.2)
		else
			GameTooltip:AddLine(format(L["AUCTION_BID_OUTBID_BY"], A:Money(entry.nextBid)), 1, 0.5, 0.1)
		end

		if entry.buyout > 0 then
			GameTooltip:AddLine(format(L["AUCTION_BID_CLICK_BUYOUT"], A:Money(entry.buyout)), 0.6, 0.6, 0.6, 1)
		else
			GameTooltip:AddLine(format(L["AUCTION_BID_CLICK_BID"], A:Money(entry.nextBid)), 0.6, 0.6, 0.6, 1)
		end

		GameTooltip:Show()
	end
	listing.OnLeave = function() GameTooltip:Hide() end

	listing.OnClick = function(entry)
		--Buyout when there is one, otherwise the next legal bid. Which of the two it
		--is gets named in the confirmation, so the click itself never has to be
		--guessed at.
		local amount = (entry.buyout > 0) and entry.buyout or entry.nextBid
		if not amount or amount <= 0 then return end

		if entry.winning and entry.buyout <= 0 then
			E:Print(L["AUCTION_BID_ALREADY_LEADING"])
			return
		end

		A.pendingBid = {entry = entry, amount = amount}

		E:StaticPopup_Show("OCTOUI_AUCTION_BID",
			format("%s x%d", entry.name, entry.count),
			format((entry.buyout > 0) and L["AUCTION_BID_AS_BUYOUT"] or L["AUCTION_BID_AS_BID"],
				A:Money(amount)))
	end

	page.OnSelect = Load
end
