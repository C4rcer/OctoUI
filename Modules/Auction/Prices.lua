local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local pairs = pairs
local format, lower, find = string.format, string.lower, string.find
local getn, sort = table.getn, table.sort
local floor, mod = math.floor, math.mod
local time = time

--[[
	The price database: what a scan saw, kept so it can be read back anywhere.

	IT IS PLAIN DATA, ON PURPOSE. Everything here writes E.global.auctionPrices
	and nothing reads it back through this file. Modules\Tooltip\Tooltip.lua
	indexes the table directly, which is what lets an item tooltip carry a price
	with the auction window switched off, or with aux installed and this module
	standing down -- prices collected before either of those happened are still
	the player's. A reader that had to go through E:GetModule("Auction") would
	lose all of that for no gain.

	Consequently EVERY FIELD IS OPTIONAL TO A READER. Records written before this
	file existed carry only unitBid, unitBuyout, seen and when; a reader that
	assumes market exists breaks on the first pre-existing database it meets.
	Degrade, do not normalise on read -- normalising would rewrite a saved
	variable on a login that never opened an auction house.

	KEYED BY ITEM NAME, not by id, because GetAuctionItemInfo only gives a name
	and that is the one field every row has. The id is stored alongside when
	GetAuctionItemLink resolves it, so the reverse lookup becomes possible later,
	but it is not the key: an id-keyed store would silently drop every row whose
	item the client had not cached yet.

	ONE RECORD PER ITEM, NOT A HISTORY. Averages over sessions are what
	Auctioneer is, it is GPL-2.0, and open item 19 in HANDOFF.md records the
	decision to treat that as its own project rather than grow into it. A fresh
	scan REPLACES the record for the items it saw: the question the store answers
	is "what is the market now", and a cheaper price from three weeks ago is not
	an answer to it.
]]

local SECONDS_PER_DAY = 86400

--Beyond this the tooltip draws the age in orange rather than grey. Not a cutoff
--- hiding a reading is the player's choice, made with auctionPriceMaxAge in the
--config. This only says "treat this with suspicion".
A.PRICE_STALE_AFTER = 7 * SECONDS_PER_DAY

--[[
	The typical asking price, weighted by how many ITEMS are on offer at it
	rather than by how many auctions there are.

	An unweighted median answers "what does a typical auction ask", which is the
	wrong question for anything sold in stacks: twelve single Copper Ore posted at
	a gold each by one optimist would out-vote three 20-stacks at 20 silver and
	report a market price nobody is paying. Weighting by stack size answers "what
	does a typical ITEM on this market cost", which is what someone deciding what
	to list at actually needs.

	Auctions with no buyout contribute nothing. They have no asking price -- a bid
	is a floor, not a price -- and folding them in would drag the figure down
	towards a number that cannot be paid.
]]
--[[
	Samples are PACKED INTO ONE NUMBER rather than kept as {value, weight} pairs:
	`price * 256 + stackSize`, with the stack size clamped to 255 (vanilla's largest
	stack is 200, so nothing real is clamped).

	This is not micro-optimisation, it is the difference between a full-auction-house
	scan working and killing the client. A pair-per-auction across 15,000 auctions is
	15,000 Lua tables that all have to be allocated and then collected, and Lua 5.0's
	collector does not keep up with that rate -- HANDOFF.md records a scan of ONE item
	taking the client to 3947 MB and killing it. Packed, an item with forty auctions is
	one array of forty numbers.

	Sorting works unchanged because the stack size occupies the low bits: ordering by
	the packed number orders by price first, which is all the median needs. THAT HOLDS
	ONLY BECAUSE THE MULTIPLIER EXCEEDS THE CLAMP -- one copper of price is 256 in packed
	space and the largest stack is 255, so a dearer auction can never sort below a
	cheaper one however big its stack. Change either number without the other and the
	median starts lying. Doubles hold integers exactly to 2^53 and the most expensive
	plausible auction packs to about 2.5e12, so there is no precision cliff near this.
]]
local STACK_CLAMP = 255

local function Pack(price, stack)
	if stack > STACK_CLAMP then stack = STACK_CLAMP end
	if stack < 1 then stack = 1 end
	return (price * 256) + stack
end

local function PackedStack(packed) return mod(packed, 256) end
local function PackedPrice(packed) return (packed - mod(packed, 256)) / 256 end

local function WeightedMedian(samples)
	local count = getn(samples)
	if count == 0 then return 0 end

	sort(samples)

	local total = 0
	for i = 1, count do total = total + PackedStack(samples[i]) end
	if total <= 0 then return PackedPrice(samples[1]) end

	local half, running = total / 2, 0
	for i = 1, count do
		running = running + PackedStack(samples[i])
		if running >= half then return PackedPrice(samples[i]) end
	end

	return PackedPrice(samples[count])
end

--The stack size a seller of this item would be competing with. Ties go to the
--larger stack: it is the harder one to undercut, and rounding advice towards the
--harder case is the safe direction to be wrong in.
local function CommonStack(stacks)
	local best, bestCount = 1, 0

	for size, count in pairs(stacks) do
		if count > bestCount or (count == bestCount and size > best) then
			best, bestCount = size, count
		end
	end

	return best
end

--[[
	Recording is STREAMED, one row at a time, and holds nothing but the summary.

	A scan of the whole auction house cannot hand over an array of every row it saw:
	that array is the thing that kills the client. So a scan opens a recording, folds
	each page into it as the page arrives, drops the page, and commits at the end. What
	survives between pages is one small table per item NAME -- a few thousand at the
	very most, against tens of thousands of auctions -- plus each item's packed price
	samples, which are bare numbers.

	The intermediate is deliberately not exposed. Nothing outside this file should be
	able to hold a reference to it, because the whole point is that it is the only
	thing alive between pages.
]]
local recording

function A:BeginRecording()
	recording = {}
end

--One auction. Takes loose values rather than a row table so a scan that is not
--building a list never has to allocate one.
function A:RecordRow(name, count, unitBid, unitBuyout, itemID, quality)
	if not (recording and name) then return end

	--[[
		Grey items are never banked, and this is the one place that decides it.

		Poor quality has no use past the vendor -- not craftable, not disenchantable,
		not a reagent for anything -- so a grey on the auction house is a troll or a
		mistake, and the price is noise. Noise costs the same to store as signal: a
		name, a record, and thirty daily points once history lands, for something
		nobody will ever look up.

		The scan still COLLECTS them, so they appear in search results where somebody
		can see what is actually listed. They simply never reach the database.
	]]
	if quality == 0 then return end

	count = count or 1
	unitBid = unitBid or 0
	unitBuyout = unitBuyout or 0

	local item = recording[name]
	if not item then
		item = {unitBid = unitBid, unitBuyout = 0, seen = 0, buyouts = {}, stacks = {}}
		recording[name] = item
	end

	if unitBid > 0 and (item.unitBid <= 0 or unitBid < item.unitBid) then
		item.unitBid = unitBid
	end

	if unitBuyout > 0 then
		if item.unitBuyout == 0 or unitBuyout < item.unitBuyout then
			item.unitBuyout = unitBuyout
		end
		item.buyouts[getn(item.buyouts) + 1] = Pack(unitBuyout, count)
	end

	item.stacks[count] = (item.stacks[count] or 0) + 1
	item.seen = item.seen + 1

	--First link that resolved wins. The client caches item data lazily, so early
	--rows of a search can arrive with no link at all.
	if not item.id and itemID then item.id = itemID end
end

--[[
	Write the recording out and drop it.

	Called when a scan finishes, INCLUDING when it was cancelled or timed out.
	Everything a partial scan saw was genuinely seen, so it is worth keeping; what a
	partial scan gets wrong is `seen`, which undercounts, and the price figures, which
	can only ever be too HIGH -- it may have missed a cheaper auction on a page it never
	read, and cannot have invented one. Erring expensive is the right direction for a
	number somebody is about to undercut.

	Returns how many item names were written.
]]
function A:CommitRecording()
	local items = recording
	recording = nil

	if not (items and E.global and E.global.auctionPrices) then return 0 end

	local now, stored = time(), 0

	for name, item in pairs(items) do
		--A full scan skips the item link, so it learns no ids. Carrying the old
		--record's id across means a whole-house scan refreshes prices without
		--throwing away what a per-item search already identified.
		local previous = E.global.auctionPrices[name]

		E.global.auctionPrices[name] = {
			id = item.id or (previous and previous.id),
			unitBid = item.unitBid,
			unitBuyout = item.unitBuyout,
			market = WeightedMedian(item.buyouts),
			seen = item.seen,
			stack = CommonStack(item.stacks),
			when = now
		}
		stored = stored + 1
	end

	return stored
end

function A:IsRecording()
	return recording and true or false
end

--How old a reading is, in the same words the tooltip uses.
function A:PriceAge(when)
	if not when then return L["never"] end

	local seconds = time() - when
	if seconds < 0 then seconds = 0 end

	if seconds < 3600 then return format(L["%dm ago"], floor(seconds / 60)) end
	if seconds < SECONDS_PER_DAY then return format(L["%dh ago"], floor(seconds / 3600)) end
	return format(L["%dd ago"], floor(seconds / SECONDS_PER_DAY))
end

--Drop readings older than days. Nothing calls this on its own: an old price is
--marked rather than deleted, because the player collected it and only they know
--whether a three-week-old reading on a stable market is still useful. This is
--the manual answer for a database that has grown noisy.
function A:PurgePrices(days)
	if not (E.global and E.global.auctionPrices) then return 0 end
	if not days or days <= 0 then return 0 end

	local cutoff = time() - (days * SECONDS_PER_DAY)
	local removed = 0

	for name, record in pairs(E.global.auctionPrices) do
		--A record with no timestamp predates the field and cannot be aged, so it is
		--left alone rather than guessed at and thrown away.
		if record.when and record.when < cutoff then
			E.global.auctionPrices[name] = nil
			removed = removed + 1
		end
	end

	return removed
end

--/octoui-ah prices [name]. With no name it reports the size and age of the
--database; with one it prints every stored item matching it, which is the only
--way to see what a tooltip will say without going and finding one of the items.
function A:PriceReport(query)
	if not (E.global and E.global.auctionPrices) then
		E:Print(L["Auction prices: nothing has been scanned yet."])
		return
	end

	query = (query and query ~= "") and lower(query) or nil

	local shown, total, oldest = 0, 0, nil

	for name, record in pairs(E.global.auctionPrices) do
		total = total + 1
		if record.when and (not oldest or record.when < oldest) then oldest = record.when end

		--Plain substring, not a pattern: item names carry brackets and hyphens that
		--a pattern match would read as syntax and either error or quietly miss.
		if query and find(lower(name), query, 1, true) then
			local unit = (record.unitBuyout and record.unitBuyout > 0) and record.unitBuyout or record.unitBid

			E:Print(format(L["AUCTION_PRICE_REPORT_ROW"],
				name,
				E:FormatMoney(unit or 0, "SMART"),
				(record.market and record.market > 0) and E:FormatMoney(record.market, "SMART") or L["unknown"],
				record.stack or 1,
				record.seen or 0,
				self:PriceAge(record.when)))

			shown = shown + 1
		end
	end

	if total == 0 then
		E:Print(L["Auction prices: nothing has been scanned yet."])
		return
	end

	E:Print(format(L["AUCTION_PRICE_REPORT_HEADER"], total, self:PriceAge(oldest)))

	if query and shown == 0 then
		E:Print(format(L["Auction prices: nothing stored matching %s."], query))
	end
end
