local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local pairs = pairs
local format = string.format
local getn, tinsert = table.getn, table.insert
local floor = math.floor
local time = time
--WoW API / Variables
local GetTime = GetTime
local GetNumAuctionItems = GetNumAuctionItems
local GetAuctionItemInfo = GetAuctionItemInfo
local GetAuctionItemTimeLeft = GetAuctionItemTimeLeft
local CanSendAuctionQuery = CanSendAuctionQuery
local QueryAuctionItems = QueryAuctionItems
local CreateFrame = CreateFrame

--[[
	The page-walking scan.

	MOVED, NOT REWRITTEN. This is OctoUI's own engine out of
	Modules\Misc\AuctionHouse.lua, where it worked and was parked in August only
	because it was annotating Blizzard's browse rows -- a presentation problem
	its own block comment says wanted a real column instead. It arrives here with
	the presentation stripped out: it takes a query, walks every page, and hands
	back rows. Nothing in it knows what a frame is.

	THE QUERY GATE IS THE WHOLE PROBLEM. The server throttles
	QueryAuctionItems and CanSendAuctionQuery is the only way to ask whether the
	next one will be accepted. Firing regardless drops pages silently -- you get
	a short result set and no error, which is the worst failure this can have. So
	every query goes through one state machine, on one OnUpdate, with one place
	that can get the gating wrong.

	IT DOES NOT NEED BLIZZARD'S FRAME. The auction session belongs to the
	auctioneer, not to AuctionFrame, so queries work with that frame hidden. What
	it does need is the session: A.atAuctionHouse, set from AUCTION_HOUSE_SHOW.
]]

local SCAN_INTERVAL = 0.4   --seconds between queries, on top of CanSendAuctionQuery
local SCAN_TIMEOUT = 15     --give up if a page never arrives
local SCAN_MAX_PAGES = 40   --hard stop, ~2000 auctions of one search

local scan = {results = {}}
A.scan = scan

local pump

local function Pump()
	if not pump then
		pump = CreateFrame("Frame")
		scan.pump = pump
	end
	return pump
end

function A:IsScanning()
	return scan.active and true or false
end

--Cheapest per unit seen for each item name, and when. One record rather than a
--history: enough to answer "is this dear today" without becoming a price
--database that has to be pruned.
local function RecordPrices()
	if not (E.global and E.global.auctionPrices) then return end

	local best = {}
	for i = 1, getn(scan.results) do
		local entry = scan.results[i]
		local record = best[entry.name]
		if not record then
			record = {unitBid = entry.unitBid, unitBuyout = 0, seen = 0}
			best[entry.name] = record
		end
		if entry.unitBid < record.unitBid then record.unitBid = entry.unitBid end
		if entry.buyout > 0 and (record.unitBuyout == 0 or entry.unitBuyout < record.unitBuyout) then
			record.unitBuyout = entry.unitBuyout
		end
		record.seen = record.seen + 1
	end

	local now = time()
	for name, record in pairs(best) do
		record.when = now
		E.global.auctionPrices[name] = record
	end
end

A.RecordPrices = RecordPrices

local function Stop()
	scan.active = false
	scan.queryPending = false
	scan.awaitingPage = false
	if pump then pump:SetScript("OnUpdate", nil) end
end

--Put the auction house back on the first page of the search. A scan ends
--wherever the last page was, and leaving it there looks exactly like the search
--broke. Gated like every other query, so it queues rather than fires.
local function RestoreFirstPage()
	if not scan.name or scan.name == "" then return end
	scan.restorePending = true
	Pump():SetScript("OnUpdate", scan.onUpdate)
end

local function Finish(reason)
	local collected = getn(scan.results)
	Stop()
	RecordPrices()

	if A.OnScanComplete then A:OnScanComplete(scan.results, reason, collected) end

	RestoreFirstPage()
end

local function CollectPage()
	local batch, total = GetNumAuctionItems("list")
	batch = batch or 0
	scan.total = total or 0
	scan.awaitingPage = false

	for i = 1, batch do
		local name, _, count, quality, _, level, minBid, _, buyoutPrice, bidAmount, _, owner =
			GetAuctionItemInfo("list", i)

		if name then
			count = (count and count > 0) and count or 1
			local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
			local buyout = buyoutPrice or 0

			tinsert(scan.results, {
				name = name,
				count = count,
				quality = quality or 1,
				level = level,
				page = scan.page,
				index = i,
				owner = owner,
				timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("list", i) or nil,
				minBid = minBid or 0,
				bid = bid,
				buyout = buyout,
				unitBid = floor((bid / count) + 0.5),
				--Zero rather than nil: the listing sorts nil last deliberately,
				--and "no buyout" must not read as "free".
				unitBuyout = (buyout > 0) and floor((buyout / count) + 0.5) or 0
			})
		end
	end

	local collected = getn(scan.results)
	if A.OnScanProgress then
		A:OnScanProgress(scan.page + 1, collected, scan.total)
	end

	if batch == 0 or collected >= scan.total or (scan.page + 1) >= SCAN_MAX_PAGES then
		Finish("done")
	else
		scan.page = scan.page + 1
		scan.queryPending = true
		scan.nextQuery = GetTime() + SCAN_INTERVAL
	end
end

A.CollectPage = CollectPage

local function OnUpdate()
	if scan.restorePending then
		if CanSendAuctionQuery() then
			scan.restorePending = false
			QueryAuctionItems(scan.name, scan.minLevel, scan.maxLevel, nil, nil, nil, 0, nil, nil)
			this:SetScript("OnUpdate", nil)
		end
		return
	end

	if not scan.active then
		this:SetScript("OnUpdate", nil)
		return
	end

	if scan.queryPending then
		if GetTime() >= scan.nextQuery and CanSendAuctionQuery() then
			scan.queryPending = false
			scan.awaitingPage = true
			scan.deadline = GetTime() + SCAN_TIMEOUT
			QueryAuctionItems(scan.name, scan.minLevel, scan.maxLevel,
				nil, nil, nil, scan.page, nil, nil)
		end
	elseif scan.awaitingPage and GetTime() > scan.deadline then
		--A page that never arrived. Keep what was collected: a partial answer is
		--worth more than none, and the alternative is throwing away nine good
		--pages because the tenth was dropped.
		Finish("timeout")
	end
end

scan.onUpdate = OnUpdate

function A:CancelScan()
	if not scan.active then return end

	local collected = getn(scan.results)
	Stop()
	if A.OnScanComplete then A:OnScanComplete(scan.results, "cancelled", collected) end
	RestoreFirstPage()
end

--name is required; the server will not answer an empty query usefully and the
--result would be "everything", which is neither what anyone meant nor something
--40 pages can hold.
function A:StartScan(name, minLevel, maxLevel)
	if scan.active then
		self:CancelScan()
		return false
	end

	if not self.atAuctionHouse then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	if not name or name == "" then
		E:Print(L["Auction house: type something to search for."])
		return false
	end

	scan.results = {}
	scan.name = name
	scan.minLevel = minLevel
	scan.maxLevel = maxLevel
	scan.page = 0
	scan.total = 0
	scan.active = true
	scan.queryPending = true
	scan.awaitingPage = false
	scan.restorePending = false
	scan.nextQuery = 0

	Pump():SetScript("OnUpdate", scan.onUpdate)
	return true
end

--Routed from the module's AUCTION_ITEM_LIST_UPDATE. Only meaningful while a
--page is outstanding; at any other time it is the server answering somebody
--else's query and reading it would mix their page into our results.
function A:AuctionListUpdated()
	if scan.active and scan.awaitingPage then
		CollectPage()
	end
end
