local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local format, lower = string.format, string.lower
local getn, tinsert, sort = table.getn, table.insert, table.sort
--WoW API
local UnitName = UnitName
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
	buy.onDone = nil
	if pump then pump:SetScript("OnUpdate", nil) end
end

--[[
	Every field that cannot change, because any one alone can collide. Two identical
	stacks from the same seller at the same price are genuinely interchangeable, so
	matching one of those is correct rather than lucky.

	MINBID, NOT THE CURRENT BID. A bid placed between the scan and the click moves
	bidAmount and leaves minBid alone, so comparing the live bid means an auction
	somebody else bid on can never be found again. HANDOFF.md records this and the
	first version of this function ignored it.

	OWNER IS COMPARED ONLY WHEN BOTH SIDES KNOW IT. Seller names arrive from the
	server AFTER the rest of a page, so a row scanned early carries owner = nil while
	the same row re-read a moment later has a name. Comparing those two directly is
	never equal, which made every single buyout report the auction as gone. The scan
	now waits for owner data, but a nil on either side still must not veto a match
	that every other field agrees on.
]]
local function Matches(entry, index)
	local name, _, count, _, _, _, minBid, _, buyoutPrice, _, _, owner =
		GetAuctionItemInfo("list", index)
	if not name then return false end

	if name ~= entry.name then return false end
	if (count or 1) ~= entry.count then return false end
	if (buyoutPrice or 0) ~= entry.buyout then return false end
	if (minBid or 0) ~= entry.minBid then return false end

	if owner and entry.owner and owner ~= entry.owner then return false end

	return true
end

local function FindAndBuy()
	local batch = GetNumAuctionItems("list")
	batch = batch or 0

	for i = 1, batch do
		if Matches(buy.entry, i) then
			local entry, amount, isBid, done = buy.entry, buy.amount, buy.isBid, buy.onDone
			Stop()

			PlaceAuctionBid("list", i, amount)

			if isBid then
				E:Print(format(L["AUCTION_BID_PLACED"], A:Money(amount), entry.name))
				A:SetStatus(format(L["AUCTION_BID_PLACED"], A:Money(amount), entry.name))
			else
				E:Print(format(L["Bought %s x%d for %s."], entry.name, entry.count, A:Money(amount)))
				A:SetStatus(format(L["Bought %s x%d."], entry.name, entry.count))
			end

			if done then done(true, entry) end
			return
		end
	end

	local done = buy.onDone
	Stop()
	E:Print(L["That auction is gone -- it sold or expired. Search again."])
	A:SetStatus(L["That auction is gone."])
	if done then done(false) end
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
		local done = buy.onDone
		Stop()
		E:Print(L["Auction house: the page did not come back. Nothing was bought."])
		if done then done(false) end
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
	text = L["AUCTION_BID_CONFIRM"],
	button1 = ACCEPT,
	button2 = CANCEL,
	OnAccept = function()
		local pending = A.pendingBuy
		A.pendingBuy = nil
		if pending then A:ConfirmedBuy(pending.entry, pending.amount, pending.isBid) end
	end,
	OnCancel = function() A.pendingBuy = nil end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1
}

--[[
	Offer to buy an auction outright, or to bid on it.

	Both go through the same machinery, because the dangerous part is identical: the
	index has to be re-found on a freshly queried page before any gold is committed.
	Only the amount and the wording differ.

	An auction with no buyout can ONLY be bid on. Clicking one used to print "that
	auction has no buyout" and stop -- a dead end, and one that also made it
	impossible to create a bid to look at on the Bids tab.
]]
function A:BuyEntry(entry, amount, isBid)
	if self:IsScanning() then
		E:Print(L["Auction house: finish or cancel the search first."])
		return
	end
	if buy.active then return end

	amount = amount or entry.buyout
	if not amount or amount <= 0 then return end

	self.pendingBuy = {entry = entry, amount = amount, isBid = isBid}

	--Two text arguments only; the stack size is folded into the first so the prompt
	--still names exactly what is being bought or bid on.
	E:StaticPopup_Show("OCTOUI_AUCTION_BUYOUT",
		format("%s x%d", entry.name, entry.count),
		format(isBid and L["AUCTION_BID_AS_BID"] or L["AUCTION_BID_AS_BUYOUT"], self:Money(amount)))
end

function A:ConfirmedBuy(entry, amount, isBid, onDone)
	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return
	end

	buy.entry = entry
	buy.amount = amount or entry.buyout
	buy.isBid = isBid
	buy.onDone = onDone
	buy.active = true
	buy.queryPending = true
	buy.awaitingPage = false

	A:SetStatus(format(L["Checking that %s is still there..."], entry.name))
	Pump():SetScript("OnUpdate", OnUpdate)
end


--------------------------------------------------------------------------------
-- Buying a quantity rather than an auction
--------------------------------------------------------------------------------

--[[
	"I want 47 Citrine."

	The auction house sells STACKS, not quantities, so a target is rarely hit
	exactly. The planner takes the cheapest per unit until the target is met or the
	supply runs out, and then says precisely what that means -- how many auctions,
	how many items, what it costs, and by how much it overshoots or falls short.
	Nothing is bought until that has been read and accepted.

	CHEAPEST PER UNIT, not cheapest per auction. Buying the cheapest listings by
	total price fills a bag with single items at bad prices; per unit is the only
	ordering that means anything when stack sizes vary.

	OWN AUCTIONS ARE EXCLUDED. You cannot buy your own, and including them in the
	plan makes it promise a quantity it can never deliver.

	Greedy, not optimal. Picking a subset of stacks to hit exactly 47 at the lowest
	price is a knapsack; walking up from the cheapest is what a person does by hand,
	gets the same answer nearly always, and can be explained in one line when it
	does not.
]]
function A:PlanPurchase(results, name, wanted)
	local player = UnitName and UnitName("player")
	local wantedLower = name and lower(name)
	local candidates = {}

	for i = 1, getn(results or {}) do
		local entry = results[i]
		if entry and entry.buyout and entry.buyout > 0
			and lower(entry.name) == wantedLower
			and entry.owner ~= player
		then
			tinsert(candidates, entry)
		end
	end

	sort(candidates, function(a, b) return a.unitBuyout < b.unitBuyout end)

	local plan, count, cost = {}, 0, 0
	for i = 1, getn(candidates) do
		if count >= wanted then break end

		local entry = candidates[i]
		tinsert(plan, entry)
		count = count + entry.count
		cost = cost + entry.buyout
	end

	return plan, count, cost
end

local bulk = {}

function A:IsBulkBuying()
	return bulk.active and true or false
end

function A:CancelBulkBuy()
	if not bulk.active then return end
	bulk.active = false
	if bulk.onDone then bulk.onDone(bulk.bought, bulk.spent, true) end
end

local function BuyNextInPlan()
	if not bulk.active then return end

	if bulk.index > getn(bulk.plan) then
		bulk.active = false
		if bulk.onDone then bulk.onDone(bulk.bought, bulk.spent, false) end
		return
	end

	local entry = bulk.plan[bulk.index]

	if bulk.onProgress then
		bulk.onProgress(bulk.index, getn(bulk.plan), bulk.bought)
	end

	--One at a time, each through the same re-query-and-re-match path a single
	--buyout uses. Anything faster would be buying by index into a page that has
	--moved, which is the whole reason that path exists.
	A:ConfirmedBuy(entry, entry.buyout, false, function(ok)
		if not bulk.active then return end

		if not ok then
			--A gone auction ends the run rather than skipping on. The prices below it
			--were chosen against a market that has just been shown to have moved.
			bulk.active = false
			if bulk.onDone then bulk.onDone(bulk.bought, bulk.spent, true) end
			return
		end

		bulk.bought = bulk.bought + entry.count
		bulk.spent = bulk.spent + entry.buyout
		bulk.index = bulk.index + 1

		BuyNextInPlan()
	end)
end

function A:StartBulkBuy(plan, onProgress, onDone)
	if bulk.active or buy.active then return false end
	if not (plan and getn(plan) > 0) then return false end

	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	bulk.plan = plan
	bulk.index = 1
	bulk.bought = 0
	bulk.spent = 0
	bulk.active = true
	bulk.onProgress = onProgress
	bulk.onDone = onDone

	BuyNextInPlan()
	return true
end
