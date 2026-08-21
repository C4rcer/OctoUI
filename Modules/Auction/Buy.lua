local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local format = string.format
local getn = table.getn
--WoW API / Variables
local GetTime = GetTime
local GetNumAuctionItems = GetNumAuctionItems
local GetAuctionItemInfo = GetAuctionItemInfo
local CanSendAuctionQuery = CanSendAuctionQuery
local QueryAuctionItems = QueryAuctionItems
local PlaceAuctionBid = PlaceAuctionBid
local CreateFrame = CreateFrame

--[[
	Buying a row out of the results.

	THE INDEX IS NOT STABLE. PlaceAuctionBid takes an index into the page the
	server last sent -- not into our collected list, and not into the page we
	happened to collect it from ten seconds ago. Buying straight off a result row
	buys whatever is sitting at that index right now, which is how people end up
	with the wrong auction at the wrong price.

	So: re-query the page the row came from, wait for it to arrive, then find the
	row again by matching name, stack size, bid, buyout and seller together. If
	it is not there any more it sold or expired, and we say so rather than buying
	its neighbour.

	AND IT ASKS FIRST. This spends real gold on a single click, so the click only
	ever opens a confirmation naming the item, the stack and the total.
]]

local BUY_TIMEOUT = 10

local buy = {}
local pump

--Same shape the scan uses: one gated state machine, one place to get it wrong.
local function Pump()
	if not pump then pump = CreateFrame("Frame") end
	return pump
end

local function Stop()
	buy.active = false
	buy.awaitingPage = false
	buy.entry = nil
	if pump then pump:SetScript("OnUpdate", nil) end
end

--Every field, because any one of them alone can collide. Two identical stacks
--from the same seller at the same price are genuinely interchangeable, so
--matching one of those is correct rather than lucky.
local function Matches(entry, index)
	local name, _, count, _, _, _, minBid, _, buyoutPrice, bidAmount, _, owner =
		GetAuctionItemInfo("list", index)
	if not name then return false end

	local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)

	return name == entry.name
		and (count or 1) == entry.count
		and (buyoutPrice or 0) == entry.buyout
		and bid == entry.bid
		and owner == entry.owner
end

local function FindAndBuy()
	local batch = GetNumAuctionItems("list")
	batch = batch or 0

	for i = 1, batch do
		if Matches(buy.entry, i) then
			local entry = buy.entry
			Stop()
			PlaceAuctionBid("list", i, entry.buyout)
			E:Print(format(L["Bought %s x%d for %s."], entry.name, entry.count,
				A:Money(entry.buyout)))
			A:SetStatus(format(L["Bought %s x%d."], entry.name, entry.count))
			return
		end
	end

	Stop()
	E:Print(L["That auction is gone -- it sold or expired. Search again."])
	A:SetStatus(L["That auction is gone."])
end

local function OnUpdate()
	if not buy.active then
		this:SetScript("OnUpdate", nil)
		return
	end

	if buy.queryPending then
		if CanSendAuctionQuery() then
			buy.queryPending = false
			buy.awaitingPage = true
			buy.deadline = GetTime() + BUY_TIMEOUT
			QueryAuctionItems(A.scan.name, A.scan.minLevel, A.scan.maxLevel,
				nil, nil, nil, buy.entry.page, nil, nil)
		end
	elseif buy.awaitingPage and GetTime() > buy.deadline then
		Stop()
		E:Print(L["Auction house: the page did not come back. Nothing was bought."])
	end
end

--Called from the module's AUCTION_ITEM_LIST_UPDATE, ahead of the scan: a buy
--and a scan never run together, and the buy is the one with money on it.
function A:BuyPageArrived()
	if buy.active and buy.awaitingPage then
		buy.awaitingPage = false
		FindAndBuy()
		return true
	end
	return false
end

function A:IsBuying()
	return buy.active and true or false
end

E.PopupDialogs["OCTOUI_AUCTION_BUYOUT"] = {
	text = L["Buy %s for %s?"],
	button1 = ACCEPT,
	button2 = CANCEL,
	OnAccept = function()
		local entry = A.pendingBuy
		A.pendingBuy = nil
		if entry then A:ConfirmedBuy(entry) end
	end,
	OnCancel = function() A.pendingBuy = nil end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1
}

function A:BuyEntry(entry)
	if self:IsScanning() then
		E:Print(L["Auction house: finish or cancel the search first."])
		return
	end
	if buy.active then return end

	self.pendingBuy = entry
	--Two text arguments only; the stack size is folded into the first so the
	--prompt still names exactly what is being bought.
	E:StaticPopup_Show("OCTOUI_AUCTION_BUYOUT",
		format("%s x%d", entry.name, entry.count), self:Money(entry.buyout))
end

function A:ConfirmedBuy(entry)
	if not self.atAuctionHouse then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return
	end

	buy.entry = entry
	buy.active = true
	buy.queryPending = true
	buy.awaitingPage = false

	A:SetStatus(format(L["Checking that %s is still there..."], entry.name))
	Pump():SetScript("OnUpdate", OnUpdate)
end
