local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local format, lower = string.format, string.lower
local getn, tinsert, sort = table.getn, table.insert, table.sort
local ceil, floor = math.ceil, math.floor
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

--[[
	A BULK RUN IS PACED, and not out of politeness.

	Every purchase used to be made from inside the previous purchase's callback, so
	a plan whose auctions all sat on the page already loaded fired every
	PlaceAuctionBid it had in a SINGLE FRAME. Two things go wrong at once there. The
	client's copy of the page cannot have changed yet, so the row just bought is
	still sitting in it and an identical second stack matches that same row again --
	the server drops the duplicate and the run believes it bought something it did
	not. And posting on this server is already known to refuse two actions a frame
	apart (see Tabs/Sell.lua), which is reason enough not to assume buying is
	different.

	Half a second between purchases lets the server's own list update land, which is
	what makes the next match a real one.
]]
local BULK_INTERVAL = 0.5

--Consecutive misses before a run gives up. One gone auction is ordinary -- somebody
--else bought it while the confirmation was on screen. Five in a row is the market
--having moved out from under the whole plan, and continuing just spends five seconds
--a time proving it.
local BULK_MAX_MISSES = 5

local buy = {}
--Declared up here, not beside the bulk-buy code below, because PageFor has to read
--it: a local declared after the function that uses it silently resolves to a nil
--global on this client.
local bulk = {}
local pump

--Same shape the scan uses: one gated state machine, one place to get it wrong.
local function Pump()
	if not pump then pump = CreateFrame("Frame") end
	return pump
end

--[[
	WHICH PAGE AN AUCTION IS ON *NOW*, which is not where the scan found it.

	`entry.page` is a position in the result set as it stood during the search. Every
	buyout REMOVES an auction from that set, so everything behind it shifts one place
	towards the front -- and anything near a page boundary crosses onto the previous
	page. Ask for the page the scan recorded and you get fifty auctions that no longer
	include the one you want; Matches then fails on all fifty and a perfectly
	available auction is reported as sold. On a plan whose auctions span more than one
	page, that turns into a run that buys the first page's worth and then misses
	everything after it.

	The correction is exact rather than a fudge: the entry's position in the result
	set, minus the number of auctions this run has already bought that sat IN FRONT
	of it. Pages hold 50 -- measured, see Scan.lua.
]]
local PAGE_SIZE = 50

local function Position(entry)
	return (entry.page or 0) * PAGE_SIZE + ((entry.index or 1) - 1)
end

local function PageFor(entry)
	local at = Position(entry)
	local shift = 0

	local bought = bulk.boughtAt
	for i = 1, getn(bought or {}) do
		if bought[i] < at then shift = shift + 1 end
	end

	local moved = at - shift
	if moved < 0 then moved = 0 end

	return floor(moved / PAGE_SIZE)
end

--[[
	WHAT A BULK RUN ACTUALLY DID, auction by auction.

	Two shortfalls have now been diagnosed from a screenshot and a sentence, and both
	times the reasoning found *a* real bug without ever proving it was *the* one that
	bit. A run that comes up short leaves nothing behind to read, so the next report
	is another round of the same guessing.

	One row per attempt: what was wanted, which page the scan found it on, which page
	was actually asked for after the shift above, and how it ended. Replaced by the
	next operation rather than accumulated, so there is nothing here to grow.

	Read it with /octoui-ah buylog.
]]
A.buyLog = A.buyLog or {}

local function LogBuy(outcome)
	local entry = buy.entry
	if not entry then return end

	tinsert(A.buyLog, {
		name = entry.name,
		count = entry.count,
		buyout = entry.buyout,
		scanPage = entry.page,
		askedPage = buy.page,
		requeried = buy.requeried and true or false,
		outcome = outcome
	})
end

local function Stop()
	buy.active = false
	buy.awaitingPage = false
	buy.entry = nil
	buy.onDone = nil
	if pump then pump:SetScript("OnUpdate", nil) end
end

--[[
	Rows already bought out of the page the client is CURRENTLY holding.

	The client's list is a snapshot: it does not change when we buy from it, it
	changes when the server sends a new one. So between those two moments the row we
	just bought is still there, still matching on every field, and a plan holding two
	identical stacks will happily buy the same one twice -- once for real, once into
	the void.

	Indices are only meaningful within one snapshot, which is why this is cleared on
	every AUCTION_ITEM_LIST_UPDATE rather than at the end of a run. Keeping a stale
	index across a refresh would skip whatever innocent auction landed on it.

	NOT AIRTIGHT, and worth knowing which way it fails. If the server ever sends a
	refresh that does not yet reflect our own purchase, the guard is cleared while the
	sold row is still listed and it could be matched again. That costs a wasted call
	the server drops -- Matches re-reads the live row, so no wrong auction is ever
	paid for -- and a purchase counted that did not happen. The real cure is
	confirming each buyout against the server the way posting confirms against
	ERR_AUCTION_STARTED, which is not built yet.
]]
local consumed = {}

function A:ForgetBoughtRows()
	consumed = {}
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

--[[
	Buy from the page the client is holding RIGHT NOW, if the auction is on it.

	Returns true when it bought. This is the whole speed of the thing: the query gate
	on this server is a flat five seconds, so a re-query costs five seconds every
	single purchase -- and the page already loaded is very often the right one. A
	single-page search never leaves it, and a bulk buy walks auctions that mostly
	share a page.

	It is exactly as safe as the slow path, because safety here has never come from
	the re-query itself. It comes from Matches, which reads the LIVE row at that index
	and checks the name, stack size, buyout and opening bid before a copper is
	committed. A stale index simply fails to match.
]]
local function TryBuyFromCurrentPage()
	local batch = GetNumAuctionItems("list")
	batch = batch or 0

	for i = 1, batch do
		if not consumed[i] and Matches(buy.entry, i) then
			local entry, amount, isBid, done = buy.entry, buy.amount, buy.isBid, buy.onDone
			Stop()

			--Marked before the call, not after: whatever happens next, this row of this
			--snapshot has been spent and must not be matched a second time.
			consumed[i] = true

			buy.entry = entry
			LogBuy(buy.requeried and "bought-requeried" or "bought-page")
			buy.entry = nil

			PlaceAuctionBid("list", i, amount)

			if isBid then
				E:Print(format(L["AUCTION_BID_PLACED"], A:Money(amount), entry.name))
				A:SetStatus(format(L["AUCTION_BID_PLACED"], A:Money(amount), entry.name))
			else
				E:Print(format(L["Bought %s x%d for %s."], entry.name, entry.count, A:Money(amount)))
				A:SetStatus(format(L["Bought %s x%d."], entry.name, entry.count))
			end

			if done then done(true, entry) end
			return true
		end
	end

	return false
end

--Reached only when the page had to be fetched. By this point the auction has been
--looked for on the page the client held AND on a freshly requested one.
local function FindAndBuy()
	if TryBuyFromCurrentPage() then return end

	LogBuy("gone")

	local done = buy.onDone
	Stop()

	--Said once for a single buyout, and not at all during a bulk run: there it is an
	--ordinary step that the run recovers from by moving to the next auction, and the
	--summary at the end reports how many were missed. Printing per miss turned one
	--stale row into a screen of identical complaints.
	if not A:IsBulkBuying() then
		E:Print(L["AUCTION_ALREADY_SOLD"])
		A:SetStatus(L["That auction is gone."])
	end

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

			--[[
				THE SAME QUERY THE RESULTS CAME FROM, category and all.

				`buy.entry.page` is a page number into one particular result set. Re-asking
				with the name but without the class, subclass, slot, quality and usable
				filters that produced it fetches page N of a DIFFERENT set, where the row
				is not going to be, and every buyout out of a category browse would report
				the auction as gone. The filters live on the scan because the scan is what
				asked the question.
			]]
			buy.requeried = true
			QueryAuctionItems(A.scan.name, A.scan.minLevel, A.scan.maxLevel,
				A.scan.invType, A.scan.class, A.scan.subclass,
				buy.page, A.scan.usable, A.scan.quality)
		elseif GetTime() > buy.deadline then
			--The gate never opened. It is a flat five seconds on this server so this
			--should not happen, and an untimed wait for something that should not happen
			--is how a run hangs with a progress bar up and nothing to report.
			LogBuy("gate-timeout")
			local done = buy.onDone
			Stop()
			if done then done(false) end
		end
	elseif buy.awaitingPage and GetTime() > buy.deadline then
		LogBuy("page-timeout")
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
		buy.entry = entry
		LogBuy("no-auctioneer")
		buy.entry = nil
		--Answered even on the way out. A bulk run drives itself from this callback, so
		--returning without it leaves the run active, the progress bar up and nothing
		--in the world that will ever move it again.
		if onDone then onDone(false) end
		return
	end

	--A single buyout replaces the log; a bulk run owns it for the whole run and
	--cleared it when it started.
	if not self:IsBulkBuying() then self.buyLog = {} end

	buy.entry = entry
	buy.amount = amount or entry.buyout
	buy.isBid = isBid
	buy.onDone = onDone
	buy.active = true
	buy.requeried = false
	--Corrected for what this run has already taken off the board. See PageFor.
	buy.page = PageFor(entry)

	--Try what is already loaded before paying five seconds to ask for it again. Most
	--purchases land here and complete instantly.
	if TryBuyFromCurrentPage() then return end

	buy.queryPending = true
	buy.awaitingPage = false
	--Covers the wait for the gate as well as the wait for the page, so neither half
	--of this can wait forever.
	buy.deadline = GetTime() + BUY_TIMEOUT

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

	CHEAPEST PER UNIT IS THE WRONG ANSWER, AND IT IS WRONG ON ORDINARY BOARDS.
	This used to walk the list in per-unit order taking whole auctions until the
	count was covered, on the reasoning that it is what a person does by hand and
	agrees with the optimum nearly always. Measured against Gargantuan Tel'Abim
	Banana with 28 wanted, it does not:

	  stacks of 10 at 3g 64s 99c  ->  36.499s a banana, the cheapest on the board
	  stacks of 2  at    73s 68c  ->  36.840s a banana

	Greedy takes three tens, overshoots to 30 and asks for 10g 94s 97c. Two tens
	and four twos is exactly 28 for 10g 24s 70c -- 70s 27c less, for two fewer
	bananas. That is seven percent of the purchase, and the shape of it is ordinary
	rather than contrived: it happens whenever the cheapest per-unit stack is larger
	than the remainder still to fill.

	THE ERROR IS ALWAYS THE LAST AUCTION. Everything before it is buying the
	cheapest units on the board. The last one is covering a REMAINDER, and covering
	a remainder of eight with a stack of ten costs whatever that stack costs -- not
	what eight bananas are worth. No ordering can see that, because the mistake only
	exists once you know what is left to fill.

	So it is a knapsack and it is solved as one: the cheapest subset of auctions
	whose stacks total at least `wanted`. Exact, with three prunes below that hold a
	board like the one above to about a thousand steps.
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

	--[[
		EXACT per-unit order, by cross-multiplication rather than off the `unitBuyout`
		field.

		That field is ROUNDED to the nearest copper because it exists to be displayed,
		so two stacks of ten priced 35s 78c and 35s 82c both read 358c each and compare
		EQUAL. Which of them then came first was whatever the sort happened to do --
		and the prune below keeps a fixed number of auctions per stack size, so it
		could throw away the cheaper of the two. Found by fuzzing this against a brute
		force: it did exactly that, and the plan came out 4c over the true optimum.

		a/count(a) < b/count(b) is a*count(b) < b*count(a) with no division and no
		float, and the products stay far inside what a double holds.
	]]
	sort(candidates, function(a, b)
		local left, right = a.buyout * b.count, b.buyout * a.count
		if left ~= right then return left < right end
		--Genuinely the same price per unit, so prefer the smaller stack: it fills a
		--remainder without overshooting, which is the whole subject below.
		return a.count < b.count
	end)

	--[[
		The old greedy answer, still computed, and it earns its keep three times over:
		it is the fallback when the board is too large to solve exactly, it is the
		answer when there is simply not enough on sale, and every auction it picks is
		guaranteed to survive the prune below -- which is what makes the table below
		always reachable.
	]]
	local greedy, greedyCount, greedyCost = {}, 0, 0
	for i = 1, getn(candidates) do
		if greedyCount >= wanted then break end

		local entry = candidates[i]
		tinsert(greedy, entry)
		greedyCount = greedyCount + entry.count
		greedyCost = greedyCost + entry.buyout
	end

	--Not enough listed to reach the target. Every auction there is IS the answer and
	--the caller reports the shortfall; there is nothing for a knapsack to choose
	--between.
	if greedyCount < wanted then return greedy, greedyCount, greedyCost end

	--[[
		PRUNE 1: at most ceil(wanted / size) auctions of any one stack size.

		One more than that is a whole stack of pure overshoot that could be dropped for
		nothing, so it cannot appear in a cheapest answer. `candidates` is already in
		per-unit order, and stacks of equal size rank the same way by unit price as by
		total, so the first few of each size are the cheapest few of that size.

		This is what makes the rest affordable. A forty-page search is two thousand
		rows; for 28 bananas across three stack sizes it keeps twenty-two.
	]]
	local seen, kept, maxStack = {}, {}, 1
	for i = 1, getn(candidates) do
		local entry = candidates[i]
		local size = entry.count
		local used = (seen[size] or 0) + 1
		seen[size] = used

		if used <= ceil(wanted / size) then
			tinsert(kept, entry)
			if size > maxStack then maxStack = size end
		end
	end

	--[[
		PRUNE 2: never hold `wanted + maxStack` or more.

		At that size any single auction can be dropped and the rest still cover the
		target, for less money -- so no cheapest answer is ever that big, and nor is
		any subset on the way to one. Transitions past the cap are DISCARDED rather
		than folded into a final bucket, which is also what keeps the count this
		returns honest: every state is a real number of items, never a saturated one.
	]]
	local cap = wanted + maxStack - 1

	--[[
		PRUNE 3: a work ceiling, with the greedy answer as the fallback.

		The table is one entry per reachable count per auction considered -- about a
		thousand steps for the banana board, and small for anything a person types into
		the Qty box. "Two thousand of a stack-of-one commodity" would build something
		this client cannot afford to think about, and its memory headroom is the
		constraint that has already killed it once during a scan. Past the ceiling this
		answers exactly as it did before rather than freezing.
	]]
	if getn(kept) * (cap + 1) > 20000 then
		return greedy, greedyCount, greedyCost
	end

	--[[
		cost[n] is the cheapest way to end up holding exactly n items, and chain[n] is
		the auctions that do it -- held as a chain of two-field tables rather than
		rebuilt per state.

		Reconstructing from a predecessor index instead would be smaller and is not
		sound here: a state can be improved again by a later auction, which leaves the
		recorded predecessor describing a route that no longer exists.
	]]
	local cost, chain = {}, {}
	cost[0] = 0

	for i = 1, getn(kept) do
		local entry = kept[i]
		local price, size = entry.buyout, entry.count

		--Downwards, so each auction is offered to the table once and cannot be bought
		--twice on the way to a single answer.
		for n = cap - size, 0, -1 do
			local base = cost[n]
			if base then
				local to = n + size
				local total = base + price

				if not cost[to] or total < cost[to] then
					cost[to] = total
					chain[to] = {entry = entry, prev = chain[n]}
				end
			end
		end
	end

	--Cheapest wins; where two land on the same money the one that overshoots least
	--wins, because two bananas nobody asked for are a cost even when they are free.
	local best
	for n = wanted, cap do
		if cost[n] and (not best or cost[n] < cost[best]) then best = n end
	end

	--The table can only fail to reach the target if greedy did, and that returned
	--above. Belt and braces: an answer is owed either way.
	if not best then return greedy, greedyCount, greedyCost end

	local plan = {}
	local link = chain[best]
	while link do
		tinsert(plan, link.entry)
		link = link.prev
	end

	--Cheapest per unit first. The order does not change what is spent, but a run that
	--is interrupted -- an auction sold out from under it, or Cancel pressed halfway --
	--has then taken the best of the board rather than the worst of it.
	sort(plan, function(a, b) return a.unitBuyout < b.unitBuyout end)

	return plan, best, cost[best]
end

local bulkPump

--Its own frame. The one above belongs to a purchase in flight, and between two
--purchases that machine is deliberately stopped.
local function BulkPump()
	if not bulkPump then bulkPump = CreateFrame("Frame") end
	return bulkPump
end

function A:IsBulkBuying()
	return bulk.active and true or false
end

function A:CancelBulkBuy()
	if not bulk.active then return end
	bulk.active = false
	if bulkPump then bulkPump:SetScript("OnUpdate", nil) end
	if bulk.onDone then bulk.onDone(bulk.bought, bulk.spent, true, bulk.missed) end
end

local BuyNextInPlan

local function BulkOnUpdate()
	if not bulk.active then
		this:SetScript("OnUpdate", nil)
		return
	end

	if GetTime() < bulk.nextAt then return end

	this:SetScript("OnUpdate", nil)
	BuyNextInPlan()
end

--Space between purchases rather than a callback calling straight back into the next
--one. See BULK_INTERVAL: the gap is what lets the server's list update arrive, and
--the arriving list is what makes the next match a real row rather than the one just
--spent.
local function ScheduleNext()
	if not bulk.active then return end

	bulk.nextAt = GetTime() + BULK_INTERVAL
	BulkPump():SetScript("OnUpdate", BulkOnUpdate)
end

local function FinishBulk(stopped)
	bulk.active = false
	if bulkPump then bulkPump:SetScript("OnUpdate", nil) end
	if bulk.onDone then bulk.onDone(bulk.bought, bulk.spent, stopped, bulk.missed) end
end

BuyNextInPlan = function()
	if not bulk.active then return end

	if bulk.index > getn(bulk.plan) then
		FinishBulk(false)
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
			--[[
				A GONE AUCTION MOVES TO THE NEXT ONE. IT DOES NOT END THE RUN.

				This used to stop dead, reasoning that the rest of the plan was chosen
				against a market that had just been shown to have moved. That is the wrong
				call for the case that actually happens: a plan is usually several IDENTICAL
				postings, and one of them being gone says nothing whatsoever about its
				twins sitting directly underneath it. Buying 28 bananas stopped at 12 and
				announced the item was no longer available while three interchangeable
				stacks of it were still on the board.

				Skipping is also the safe direction. Every auction in the plan was priced
				and confirmed individually, so dropping one only ever spends LESS than the
				total that was agreed to -- it can never spend more.
			]]
			bulk.missed = bulk.missed + 1
			bulk.misses = bulk.misses + 1

			if bulk.misses >= BULK_MAX_MISSES then
				FinishBulk(true)
				return
			end

			bulk.index = bulk.index + 1
			ScheduleNext()
			return
		end

		bulk.misses = 0
		bulk.bought = bulk.bought + entry.count
		bulk.spent = bulk.spent + entry.buyout
		--Where it sat in the result set, so every auction still to come knows how far
		--the list has shifted underneath it.
		tinsert(bulk.boughtAt, Position(entry))
		bulk.index = bulk.index + 1

		ScheduleNext()
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
	--Total gone auctions, and the run of them since the last success. One is
	--ordinary; five in a row is the market rather than bad luck.
	bulk.missed = 0
	bulk.misses = 0
	--Positions of what has been bought, for the page correction in PageFor.
	bulk.boughtAt = {}
	bulk.active = true

	self.buyLog = {}
	bulk.onProgress = onProgress
	bulk.onDone = onDone

	BuyNextInPlan()
	return true
end

--[[
	The last run, printed. `/octoui-ah buylog`.

	`scan` is the page the search recorded, `asked` the page actually queried after
	correcting for what the run had already taken off the board. Those two differing
	is normal on a multi-page plan and is the point of recording both -- if a run
	comes up short with rows reading `gone` while scan and asked are equal, the
	auctions really did sell; if they read `gone` while the two differ, the
	correction is wrong and that is a bug here rather than a busy market.
]]
function A:BuyLogReport()
	local rows = self.buyLog
	local n = getn(rows or {})

	if n == 0 then
		E:Print(L["AUCTION_BUYLOG_EMPTY"])
		return
	end

	E:Print(format(L["AUCTION_BUYLOG_HEADER"], n))

	for i = 1, n do
		local row = rows[i]
		E:Print(format(L["AUCTION_BUYLOG_ROW"], i, row.name or "?", row.count or 0,
			self:Money(row.buyout), row.scanPage or -1, row.askedPage or -1,
			row.outcome or "?"))
	end
end
