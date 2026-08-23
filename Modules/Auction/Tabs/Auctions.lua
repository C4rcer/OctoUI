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
local GetOwnerAuctionItems = GetOwnerAuctionItems
local CancelAuction = CancelAuction
local GetItemQualityColor = GetItemQualityColor
local GetTime = GetTime
local GameTooltip = GameTooltip

--[[
	The Auctions tab: what you have up, and cancelling it.

	YOUR OWN AUCTIONS ARE A DIFFERENT RESULT SET. They are not in the "list" set that
	QueryAuctionItems fills -- they live in "owner", fetched with
	GetOwnerAuctionItems(page). Two consequences that are easy to get wrong:

	  * It is NOT gated on CanSendAuctionQuery. That gate throttles the browse query
	    only; a working auction addon on this client submits owner and bidder
	    requests without asking, and waiting on the gate here just stalls.
	  * The answer arrives on AUCTION_OWNED_LIST_UPDATE, not AUCTION_ITEM_LIST_UPDATE,
	    and it arrives for whichever page the server felt like answering. The page
	    that was asked for has to be remembered and checked.

	CANCELLING RE-READS FIRST. CancelAuction takes an index into the owner list as
	the server last sent it, and that list shifts the moment anything expires, sells
	or is cancelled. Cancelling straight off a row that was fetched a minute ago
	cancels whatever is at that index now. So a cancel re-fetches, finds the auction
	again by its own fields, and only then cancels -- the same reasoning as buying in
	Buy.lua, for the same reason.
]]

local FETCH_TIMEOUT = 8
local MAX_PAGES = 20

local owner = {results = {}}

local function BuildRow(index, page)
	local name, _, count, quality, _, level, minBid, _, buyoutPrice, bidAmount, highBidder =
		GetAuctionItemInfo("owner", index)
	if not name then return nil end

	count = (count and count > 0) and count or 1
	local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
	local buyout = buyoutPrice or 0

	return {
		name = name,
		count = count,
		quality = quality or 1,
		level = level,
		page = page,
		index = index,
		minBid = minBid or 0,
		bid = bid,
		buyout = buyout,
		--Nil rather than an empty string, so the column can tell "nobody has bid" from
		--"somebody has bid and the client has not told us who".
		highBidder = (highBidder and highBidder ~= "") and highBidder or nil,
		--Buyout where there is one, bid where there is not: an auction with no buyout
		--still has a total, and "--" loses the only price it has.
		total = (buyout > 0) and buyout or bid,
		unitBid = floor((bid / count) + 0.5),
		unitBuyout = (buyout > 0) and floor((buyout / count) + 0.5) or 0,
		timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("owner", index) or nil
	}
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

local pump

local function Stop()
	owner.active = false
	if pump then pump:SetScript("OnUpdate", nil) end
end

local function Finish(reason)
	Stop()
	if owner.onDone then owner.onDone(owner.results, reason) end
end

--[[
	THE EVENT IS NOT GUARANTEED TO ARRIVE. AUCTION_OWNED_LIST_UPDATE fires when the
	server sends the owner list, and asking again for a list it has already sent and
	which has not changed can be answered from the client's own copy with no event at
	all. Waiting only for the event is what turned a working Auctions tab into an
	empty one with "the auction house did not send your auctions back" a few seconds
	later -- the data was sitting right there.

	So the event is an accelerator, not the trigger. After a short grace period the
	list is read regardless, because by then it is either there or it is not coming.
]]
local GRACE = 0.4

local function RequestPage(page)
	owner.page = page
	owner.awaiting = true
	owner.readAt = GetTime() + GRACE
	owner.deadline = GetTime() + FETCH_TIMEOUT
	GetOwnerAuctionItems(page)
end

--[[
	What a page contains, as one string.

	The owner list does not necessarily honour the page argument: asking for page 1
	can be answered with page 0 all over again, and the reported total can exceed what
	is actually served. Paging blindly on the total then appends the same auctions a
	second time -- four auctions became eight, one Skullflame Shield became two, and
	the count at the bottom cheerfully agreed.

	Two pages that are byte-for-byte identical are not a thing that legitimately
	happens; even two identical stacks differ by their position in the list. So an
	identical page is the server saying "there is no page 1", and the walk stops.
]]
local function PageSignature(batch)
	local parts = ""
	for i = 1, batch do
		local name, _, count, _, _, _, minBid, _, buyoutPrice = GetAuctionItemInfo("owner", i)
		parts = parts..(name or "?")..":"..(count or 0)..":"..(minBid or 0)..":"..(buyoutPrice or 0)..";"
	end
	return parts
end

local function Consume()
	if not (owner.active and owner.awaiting) then return end
	owner.awaiting = false

	local batch, total = GetNumAuctionItems("owner")
	batch = batch or 0
	owner.total = total or 0

	local signature = PageSignature(batch)
	if batch > 0 and signature == owner.lastSignature then
		Finish("done")
		return
	end
	owner.lastSignature = signature

	for i = 1, batch do
		local row = BuildRow(i, owner.page)
		if row then tinsert(owner.results, row) end
	end

	local collected = getn(owner.results)

	if batch == 0 or collected >= owner.total or (owner.page + 1) >= MAX_PAGES then
		Finish("done")
	else
		RequestPage(owner.page + 1)
	end
end

local function OnUpdate()
	if not owner.active then
		this:SetScript("OnUpdate", nil)
		return
	end

	if not owner.awaiting then return end

	if GetTime() >= owner.readAt then
		Consume()
	elseif GetTime() > owner.deadline then
		Finish("timeout")
	end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
watcher:SetScript("OnEvent", function() Consume() end)

function A:FetchOwnAuctions(onDone)
	if owner.active then return false end
	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	owner.results = {}
	owner.total = 0
	owner.lastSignature = nil
	owner.active = true
	owner.onDone = onDone

	if not pump then pump = CreateFrame("Frame") end
	pump:SetScript("OnUpdate", OnUpdate)

	RequestPage(0)
	return true
end

function A:IsFetchingOwn()
	return owner.active and true or false
end

--Stop without telling anyone. Used when something more important than a list
--refresh needs the fetch machinery.
local function AbortFetch()
	Stop()
	owner.onDone = nil
end

--------------------------------------------------------------------------------
-- Cancelling
--------------------------------------------------------------------------------

--Every field, because any one alone can collide: two identical stacks at the same
--price genuinely are interchangeable, so matching either of those is correct.
local function Matches(entry, index)
	local name, _, count, _, _, _, minBid, _, buyoutPrice = GetAuctionItemInfo("owner", index)
	if not name then return false end

	return name == entry.name
		and (count or 1) == entry.count
		and (buyoutPrice or 0) == entry.buyout
		and (minBid or 0) == entry.minBid
end

function A:CancelOwnAuction(entry, onDone)
	--Re-read before acting. The index in `entry` was true when the list was
	--fetched; anything expiring or selling since has shifted everything below it.
	--A refresh already in flight would make FetchOwnAuctions refuse, and the callback
	--below would never run -- a cancel that silently did nothing, which is exactly
	--what "gives the pop up then nothing" was. The in-flight fetch is only redrawing
	--a list; the cancel is the one with gold on it, so it takes over.
	if self:IsFetchingOwn() then AbortFetch() end

	self:FetchOwnAuctions(function(results, reason)
		if reason ~= "done" then
			E:Print(L["AUCTION_CANCEL_NO_LIST"])
			if onDone then onDone(false) end
			return
		end

		local batch = GetNumAuctionItems("owner") or 0
		for i = 1, batch do
			if Matches(entry, i) then
				CancelAuction(i)
				E:Print(format(L["AUCTION_CANCELLED"], entry.name, entry.count))
				if onDone then onDone(true) end
				return
			end
		end

		E:Print(L["AUCTION_CANCEL_GONE"])
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

--[[
	Column weights are relative, and the three money columns are deliberately generous.

	They have to fit the widest price this client can produce -- 9999g 99s 99c, thirteen
	visible characters -- and a money string that does not fit is TRUNCATED, so "649g
	99s 99c" renders as "649g 99..." and the number is simply wrong to read. Item names
	clip harmlessly; prices do not. At the window's width these land near 127px each,
	which holds the maximum with room to spare.
]]
local COLUMNS = {
	{key = "name", label = L["Item"], width = 26, color = QualityColor},
	{key = "count", label = L["Qty"], width = 5, justify = "RIGHT"},
	{key = "unitBid", label = L["Bid/ea"], width = 17, justify = "RIGHT",
		format = function(v) return A:Money(v) end},
	{key = "unitBuyout", label = L["Buyout/ea"], width = 17, justify = "RIGHT",
		emptyLast = true,
		format = function(v) return v > 0 and A:Money(v) or "|cff808080--|r" end},
	{key = "total", label = L["Total"], width = 17, justify = "RIGHT",
		format = function(v, entry)
			if not v or v <= 0 then return "|cff808080--|r" end
			if entry.buyout > 0 then return A:Money(v) end
			return "|cff9d9d9d"..A:Money(v).."|r"
		end},
	{key = "timeLeft", label = L["Time"], width = 6, justify = "RIGHT",
		format = function(v)
			local text = {"30m", "2h", "8h", "24h"}
			return v and text[v] or ""
		end},
	{key = "highBidder", label = L["Bidder"], width = 12,
		format = function(v) return v or "|cff808080--|r" end}
}

A.tabBuilders = A.tabBuilders or {}

A.tabBuilders["auctions"] = function(page)
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
	hint:SetText(L["AUCTION_OWN_HINT"])
	hint:SetTextColor(0.6, 0.6, 0.6)

	local listing = A:CreateListing(page, COLUMNS, ROWS, 740)
	E:Point(listing, "TOPLEFT", page, "TOPLEFT", 0, -26)
	E:Point(listing, "BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	listing.sortColumn = 6
	listing.sortDescending = false

	local function Load()
		if A:IsFetchingOwn() then return end

		A:SetStatus(L["AUCTION_OWN_LOADING"])

		A:FetchOwnAuctions(function(results, reason)
			if reason == "timeout" then
				--Keep whatever is already on screen. Blanking the list because a
				--refresh failed loses information the player had a moment ago and
				--makes a hiccup look like "you have no auctions".
				A:SetStatus(L["AUCTION_OWN_TIMEOUT"])
				return
			end

			listing:SetData(results)
			A:SetStatus(format(L["AUCTION_OWN_COUNT"], getn(results)))
		end)
	end

	page.listing = listing
	refresh:SetScript("OnClick", Load)

	E.PopupDialogs["OCTOUI_AUCTION_CANCEL"] = {
		text = L["AUCTION_CANCEL_CONFIRM"],
		button1 = ACCEPT,
		button2 = CANCEL,
		OnAccept = function()
			local entry = A.pendingCancel
			A.pendingCancel = nil
			if entry then A:CancelOwnAuction(entry, function() Load() end) end
		end,
		OnCancel = function() A.pendingCancel = nil end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1
	}

	listing.OnEnter = function(entry, row)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:AddLine(entry.name)
		if entry.count > 1 then
			GameTooltip:AddLine(format(L["Stack of %d"], entry.count), 1, 1, 1)
		end
		if entry.highBidder then
			GameTooltip:AddLine(format(L["AUCTION_OWN_HAS_BID"], A:Money(entry.bid)), 1, 0.5, 0.1)
		end
		GameTooltip:AddLine(L["AUCTION_OWN_CLICK_CANCEL"], 0.6, 0.6, 0.6, 1)
		GameTooltip:Show()
	end
	listing.OnLeave = function() GameTooltip:Hide() end

	listing.OnClick = function(entry)
		A.pendingCancel = entry
		E:StaticPopup_Show("OCTOUI_AUCTION_CANCEL",
			format("%s x%d", entry.name, entry.count),
			--A bid already placed is lost gold: vanilla keeps the deposit when an
			--auction with a bid on it is cancelled. Saying so in the prompt is the
			--only place it can be said before the decision is made.
			entry.highBidder and L["AUCTION_CANCEL_LOSES_DEPOSIT"] or L["AUCTION_CANCEL_NO_BIDS"])
	end

	--Loaded when the tab is opened rather than when the window is built, so someone
	--who never looks at it never pays for the fetch.
	page.OnSelect = Load
end
