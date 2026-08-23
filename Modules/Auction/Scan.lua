local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local tonumber = tonumber
local find, format = string.find, string.format
local tinsert, getn = table.insert, table.getn
local floor, ceil, mod = math.floor, math.ceil, math.mod
--WoW API / Variables
local GetTime = GetTime
local GetNumAuctionItems = GetNumAuctionItems
local GetAuctionItemInfo = GetAuctionItemInfo
local GetAuctionItemLink = GetAuctionItemLink
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
--Per ATTEMPT, not per page. A dropped query is re-sent up to SCAN_RETRIES times
--before a page is called lost; the total budget is the same as the old single
--15s wait, but a silent first query no longer ends the scan.
local SCAN_TIMEOUT = 5
local SCAN_RETRIES = 3
local SCAN_MAX_PAGES = 40   --hard stop, ~2000 auctions of one search

--[[
	The full scan: every auction on the realm, folded into the price database.

	THIS IS A DIFFERENT SHAPE OF SCAN, not the search with the box left empty, and the
	difference is the one thing that decides whether it works. A search scan keeps every
	row, because the search tab draws them in a sortable list. Keeping every row is
	exactly what killed the client at 3947 MB on ELEVEN pages of a single item
	(HANDOFF.md, 2026-08-06) -- a whole auction house is ten to thirty times that, so a
	full scan that accumulated rows would not merely be slow, it would be a guaranteed
	crash.

	So it accumulates nothing. Each page is folded straight into the recording in
	Prices.lua and then dropped: no row tables, no results array, no item links. What
	survives between pages is one small table per item name and a flat array of packed
	numbers, which is a few hundred kilobytes for the entire realm.

	Most of the memory is still the client's own -- every page it answers carries its
	build's item data for fifty rows, and nothing an addon does changes that. Which is
	why this is also PACED and CAPPED rather than run flat out, and why the honest
	advice before a first full scan is to restart the client.

	The item link is skipped deliberately. It is a string allocation per auction for a
	field nothing reads yet, and Prices.lua carries the previous record's id across a
	commit so a full scan refreshes prices without discarding what a search already
	identified.
]]
--[[
	WHY THE PAGE CAP IS A SETTING AND THE SCAN RESUMES.

	The measured crash is not proportional to what the addon stores, it is proportional
	to how many DISTINCT ITEMS the client has been made to load. A full scan touches
	every unique item on the realm, which is the worst case that exists for it. Eleven
	pages of one item spent about a gigabyte of a gigabyte of headroom, and most of that
	was the client caching item data, not us.

	So a full scan stops at a cap the player controls and remembers where it stopped.
	Press it again and it carries on from the next page. Three passes of thirty pages
	with the same database at the end is the difference between a feature that works on
	this client and one that crashes it -- and if a machine turns out to cope, the cap
	goes up and it becomes one pass.

	The resume point is deliberately NOT saved across sessions. It is a page number into
	a result set the server rebuilds constantly; resuming at page 40 tomorrow reads
	somebody else's auctions, not the continuation of yesterday's.
]]
--Confirmed against a working auction addon on this client: pages hold 50.
local PAGE_SIZE = 50
local FULL_SCAN_DEFAULT_PAGES = 25
local FULL_SCAN_INTERVAL = 0.5    --slightly kinder than a search: this one runs for minutes

--[[
	Zero means no limit, and that is the default now.

	The cap used to stop a full scan part-way and wait for the player to press the
	button again. That is a chore rather than a safeguard: a scan that needs shepherding
	is one nobody finishes. It runs to the end on its own and Cancel is always there.

	The setting survives as a hard ceiling for anyone whose machine struggles -- the
	memory note in the block above is real -- but it is opt-in rather than the default
	experience.
]]
--The scan's own state. Declared HERE, above everything that reads it: the pacing
--functions below touch scan.cleanPages, and a local declared after them makes that
--a nil global inside those closures -- which is precisely how this broke.
local scan = {results = {}}
A.scan = scan

--[[
	THE PACE IS LEARNED, NOT CHOSEN.

	A whole auction house is over a thousand pages here, so the difference between
	half a second and five seconds a page is ten minutes against nearly two hours.
	Nobody can pick that number from a chair: it belongs to the server, it is not
	published, and a working addon on this client just waits on CanSendAuctionQuery
	and adds nothing of its own.

	So find it. Every page that arrives first time is evidence the current pace is
	acceptable, and after a few of those the interval drops a notch. A page that has
	to be RE-SENT is evidence it is not -- a dropped query is exactly what going too
	fast looks like here, since the server answers by saying nothing at all -- so the
	interval jumps back up and that speed is remembered as a floor never to go below
	again.

	The floor is per account and survives the session, so the cost of finding it is
	paid once rather than at the start of every scan. `/octoui-ah rate` shows where it
	settled, and `/octoui-ah rate reset` forgets it if a server changes its mind.
]]
local INTERVAL_MIN, INTERVAL_MAX = 0, 3.0
local INTERVAL_STEP_DOWN = 0.05
local INTERVAL_STEP_UP = 0.35
local CLEAN_PAGES_BEFORE_SPEEDUP = 4

local function LearnedInterval()
	local db = A:Settings()
	if not db.scanInterval then
		db.scanInterval = FULL_SCAN_INTERVAL
	end
	return db.scanInterval
end

local function SetInterval(value)
	local db = A:Settings()

	if value < INTERVAL_MIN then value = INTERVAL_MIN end
	if value > INTERVAL_MAX then value = INTERVAL_MAX end

	--Never back below a pace already shown to drop queries.
	local floorValue = db.scanIntervalFloor
	if floorValue and value < floorValue then value = floorValue end

	db.scanInterval = value
	return value
end

--A page arrived without needing to be re-sent. Evidence, not proof: it takes a run
--of them before the pace moves, so one lucky page cannot wind the whole scan up.
local function PageWasClean()
	scan.cleanPages = (scan.cleanPages or 0) + 1
	if scan.cleanPages < CLEAN_PAGES_BEFORE_SPEEDUP then return end

	scan.cleanPages = 0
	SetInterval(LearnedInterval() - INTERVAL_STEP_DOWN)
end

--A page had to be re-sent. That pace is now known to be too fast, and is recorded
--as a floor so no later run wanders back down into it.
local function PageWasDropped()
	local db = A:Settings()
	local at = LearnedInterval()

	db.scanIntervalFloor = at + INTERVAL_STEP_UP
	scan.cleanPages = 0
	SetInterval(at + INTERVAL_STEP_UP)
end

local function FullScanCap()
	local pages = A:Settings().scanPages
	if not pages or pages < 1 then return nil end
	return pages
end


--[[
	MEASURING THE REAL RATE LIMIT, because nobody has.

	Two things pace a scan and only one of them is ours. The server's own gate,
	CanSendAuctionQuery, decides whether the next query will be accepted at all;
	SCAN_INTERVAL is an extra delay this addon adds on top, chosen on the reasoning
	that the gate answers "will this be accepted" rather than "is this a sensible
	rate". That was an assumption. A working auction addon on this client adds no
	interval whatsoever and waits only on the gate.

	So: measure both. `gate` is how long after a query the gate reopens; `page` is
	how long the answer takes to arrive. If the gate reopens well inside
	SCAN_INTERVAL then the interval is the bottleneck and can go. If it does not,
	the interval is doing nothing and can go for a different reason.

	Read it with /octoui-ah rate after a scan. Bounded, because a full-house scan
	would otherwise collect thousands of samples nobody reads.
]]
local TIMING_SAMPLES = 200

A.scanTimings = A.scanTimings or {}

function A:RecordScanTiming(kind, seconds)
	if not (seconds and seconds >= 0) then return end

	local bucket = self.scanTimings[kind]
	if not bucket then
		bucket = {n = 0, total = 0, min = seconds, max = seconds, samples = {}}
		self.scanTimings[kind] = bucket
	end

	bucket.n = bucket.n + 1
	bucket.total = bucket.total + seconds
	if seconds < bucket.min then bucket.min = seconds end
	if seconds > bucket.max then bucket.max = seconds end

	--Kept only so a future change could look at the distribution rather than the
	--summary; the running figures above are what the report prints.
	local slot = mod(bucket.n - 1, TIMING_SAMPLES) + 1
	bucket.samples[slot] = seconds
end

function A:ScanRateReport()
	local order = {"gate", "page"}
	local any = false

	for i = 1, getn(order) do
		local kind = order[i]
		local bucket = self.scanTimings[kind]
		if bucket and bucket.n > 0 then
			any = true
			E:Print(format(L["AUCTION_RATE_LINE"], kind, bucket.n,
				bucket.min, bucket.total / bucket.n, bucket.max))
		end
	end

	if not any then
		E:Print(L["AUCTION_RATE_NONE"])
		return
	end

	local db = self:Settings()
	local pace = db.scanInterval or FULL_SCAN_INTERVAL

	--A floor only exists once some pace has actually dropped a query. Printing 0.00
	--as though zero were the guilty pace reads as the opposite of what happened.
	if db.scanIntervalFloor then
		E:Print(format(L["AUCTION_RATE_LEARNED"], pace, db.scanIntervalFloor))
	else
		E:Print(format(L["AUCTION_RATE_LEARNED_CLEAN"], pace))
	end

	--Run mid-scan, which is the natural thing to do while waiting for one, the
	--figures below would otherwise describe the PREVIOUS scan while the samples
	--above describe the one still running.
	if scan.active then
		E:Print(format(L["AUCTION_RATE_RUNNING"], scan.page + 1, scan.collected, scan.total))
		return
	end

	local last = self.lastScan
	if last then
		E:Print(format(L["AUCTION_RATE_LAST"], last.full and L["full scan"] or L["search"],
			last.pages, last.auctions, last.total or 0, last.reason or "?"))
	end
end

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
	local collected = scan.collected
	Stop()

	--Committed before the tab is told, so a tooltip hovered the moment a scan
	--finishes is already reading the new numbers. Prices.lua owns the record shape
	--and the reasoning about partial scans.
	scan.stored = A:CommitRecording()

	--What the last scan actually did, so the rate figures can be read against the
	--work that produced them. Two samples from a two-page scan says nothing; the same
	--two from a scan that should have read two hundred says a great deal.
	A.lastScan = {
		pages = (scan.page - (scan.firstPage or 0)) + 1,
		auctions = collected,
		total = scan.total,
		full = scan.full and true or false,
		reason = reason
	}

	local handlers = scan.handlers
	if handlers and handlers.complete then
		handlers.complete(scan.results, reason, collected, scan.stored)
	end

	RestoreFirstPage()
end

--[[
	Have the seller names arrived yet?

	The server sends a page and then fills in its owner names, so a page read the
	instant it lands has rows with owner = nil. Those rows are unusable for anything
	that has to find the same auction again later -- buying matched on owner and so
	failed on every attempt, reporting the auction gone when it was sitting there.

	Only the search scan cares. A full scan stores prices, never re-finds a row, and
	waiting for names across hundreds of pages would double how long it takes.
]]
local function OwnerDataComplete(batch)
	for i = 1, batch do
		local name, _, _, _, _, _, _, _, _, _, _, owner = GetAuctionItemInfo("list", i)
		if name and not owner then return false end
	end
	return true
end

local function CollectPage()
	local batch, total = GetNumAuctionItems("list")
	batch = batch or 0

	--Give the seller names a moment to turn up, then take the page regardless: a page
	--with some names missing is still worth more than no page at all.
	if not scan.full and batch > 0 and not OwnerDataComplete(batch) then
		if not scan.ownerDeadline then scan.ownerDeadline = GetTime() + 1.5 end
		if GetTime() < scan.ownerDeadline then return end
	end
	scan.ownerDeadline = nil

	if scan.lastQueryAt then
		A:RecordScanTiming("page", GetTime() - scan.lastQueryAt)
	end

	scan.total = total or 0
	scan.awaitingPage = false

	--Read before it is cleared: whether THIS page needed re-sending is the whole
	--signal the pacing learns from.
	if (scan.retries or 0) > 0 then PageWasDropped() else PageWasClean() end
	scan.retries = 0

	for i = 1, batch do
		local name, _, count, quality, _, level, minBid, _, buyoutPrice, bidAmount, _, owner =
			GetAuctionItemInfo("list", i)

		if name then
			count = (count and count > 0) and count or 1
			local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
			local buyout = buyoutPrice or 0
			local unitBid = floor((bid / count) + 0.5)
			--Zero rather than nil: the listing sorts nil last deliberately, and "no
			--buyout" must not read as "free".
			local unitBuyout = (buyout > 0) and floor((buyout / count) + 0.5) or 0

			--BOTH kinds of scan record. The only thing `full` decides is whether the
			--row is also kept for the listing to draw -- the price database is filled
			--the same way either way, so a search still teaches it what it saw.
			if scan.full then
				--Folded in and forgotten. Nothing about this row outlives the loop.
				A:RecordRow(name, count, unitBid, unitBuyout, nil)
			else
				--The link is the only place an item ID is available here --
				--GetAuctionItemInfo does not return one. It is nil for a row whose item
				--the client has not cached yet, which is ordinary rather than an error,
				--so everything downstream treats both the link and the id as optional.
				local link = GetAuctionItemLink and GetAuctionItemLink("list", i) or nil
				local itemID = nil
				if link then
					local _, _, id = find(link, "item:(%d+)")
					itemID = id and tonumber(id) or nil
				end

				A:RecordRow(name, count, unitBid, unitBuyout, itemID)

				tinsert(scan.results, {
					name = name,
					count = count,
					quality = quality or 1,
					level = level,
					page = scan.page,
					index = i,
					owner = owner,
					link = link,
					itemID = itemID,
					timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("list", i) or nil,
					minBid = minBid or 0,
					bid = bid,
					buyout = buyout,
					--What the server will actually accept as the next bid. Anything less is
					--refused with an error that does not explain itself.
					nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minIncrement or 0)) or (minBid or 0),
					--What the whole stack costs. The buyout where there is one, otherwise
					--what the bid would cost -- an auction with no buyout still has a
					--total, and showing "--" there loses the only price it has.
					total = (buyout > 0) and buyout or bid,
					unitBid = unitBid,
					unitBuyout = unitBuyout
				})
			end

			scan.collected = scan.collected + 1
		end
	end

	local collected = scan.collected

	--Total pages is arithmetic on the total the server just reported. A progress bar
	--needs it, and so does the stop test below, so it is computed once here.
	local totalPages = (scan.total > 0) and ceil(scan.total / PAGE_SIZE) or 0

	scan.pagesRead = (scan.pagesRead or 0) + 1

	--[[
		Time left, from what this scan has actually managed rather than from the
		configured interval. Over a thousand pages the two diverge badly: the pace is
		being tuned as it goes, and early pages are not representative of later ones.
		Measured throughput is the only honest estimate.
	]]
	local eta
	if scan.startedAt and scan.pagesRead > 0 and totalPages > 0 then
		local perPage = (GetTime() - scan.startedAt) / scan.pagesRead
		local left = totalPages - (scan.page + 1)
		if left > 0 then eta = perPage * left end
	end

	local handlers = scan.handlers
	if handlers and handlers.progress then
		handlers.progress(scan.page + 1, collected, scan.total, totalPages, eta)
	end

	--[[
		Knowing when the walk is over.

		A running count against the reported total only works for a scan that started at
		page 0, and a resumed full scan does not: its count begins at zero part-way
		through the result set and would never reach the total.

		The page index of the last page is arithmetic on the total the server just gave
		us: pages hold 50, they are numbered from zero, so the last one is
		ceil(total / 50) - 1. Confirmed against a working auction addon on this client
		rather than assumed -- the page size is not something an addon can ask for, and
		guessing it wrong means either stopping a page early or querying past the end
		forever.

		A short or empty page is kept as a second, independent stop. If the total ever
		disagrees with what is actually served, the walk still terminates.
	]]
	local lastPageIndex = (totalPages > 0) and (totalPages - 1) or 0
	local lastPage = (batch == 0) or (batch < PAGE_SIZE) or (scan.page >= lastPageIndex)

	--The cap counts pages read in THIS pass, not absolute page numbers, so a resumed
	--scan gets a full budget of its own rather than finishing immediately.
	--[[
		Written out rather than `scan.full and FullScanCap() or SCAN_MAX_PAGES`.

		FullScanCap returns nil to mean "no ceiling", and in that idiom a nil middle
		term falls through to the right-hand side -- so an unlimited full scan silently
		became a 40-page one, which is the search cap and has nothing to do with it.
		The and/or trick cannot express "nil is a real answer".
	]]
	local cap
	if scan.full then
		cap = FullScanCap()
	else
		cap = SCAN_MAX_PAGES
	end
	local read = (scan.page - scan.firstPage) + 1
	local capped = cap and (not lastPage) and read >= cap

	if lastPage or capped or (not scan.full and collected >= scan.total) then
		--Where the next pass picks up. Cleared on a clean finish so pressing the
		--button again after a completed scan starts over rather than off the end.
		A.scanResume = capped and (scan.page + 1) or nil
		Finish(capped and "capped" or "done")
	else
		scan.page = scan.page + 1
		scan.queryPending = true
		scan.nextQuery = GetTime() + LearnedInterval()
	end
end

A.CollectPage = CollectPage

local function OnUpdate()
	--Polled regardless of whether we are ready to send, because the point is to time
	--the SERVER's gate rather than our own interval sitting in front of it.
	if scan.lastQueryAt and not scan.gateSeen and CanSendAuctionQuery() then
		scan.gateSeen = true
		A:RecordScanTiming("gate", GetTime() - scan.lastQueryAt)
	end

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
			scan.pageArrived = false
			scan.ownerDeadline = nil
			scan.deadline = GetTime() + SCAN_TIMEOUT
			scan.lastQueryAt = GetTime()
			scan.gateSeen = false
			QueryAuctionItems(scan.name, scan.minLevel, scan.maxLevel,
				nil, nil, nil, scan.page, nil, nil)
		end
	elseif scan.awaitingPage and scan.pageArrived then
		--The page is here but its seller names may not be. CollectPage returns without
		--consuming it until they are, or until it has waited long enough.
		CollectPage()
	elseif scan.awaitingPage and GetTime() > scan.deadline then
		--[[
			A page that never arrived is RE-SENT, not fatal.

			QueryAuctionItems can be accepted and then simply not answered -- no page,
			no error, nothing. Treating the first silence as the end of the scan is how
			a whole-house scan reports "0 auctions" having asked exactly once and been
			ignored once. A working auction addon on this client re-submits on the same
			timeout rather than giving up, which is the tell that the silence is common
			enough to be designed around rather than exceptional.

			The budget is spent as several short attempts instead of one long wait, so
			a dropped first query costs seconds rather than the whole scan.
		]]
		if scan.retries < SCAN_RETRIES then
			scan.retries = scan.retries + 1
			scan.awaitingPage = false
			scan.queryPending = true
			scan.nextQuery = GetTime() + LearnedInterval()
		else
			--Out of attempts. Keep what was collected: a partial answer is worth more
			--than none, and the alternative is throwing away nine good pages because
			--the tenth was dropped.
			Finish("timeout")
		end
	end
end

scan.onUpdate = OnUpdate

function A:CancelScan()
	if not scan.active then return end

	local collected = scan.collected
	Stop()

	--A cancelled scan banks what it read, exactly as a timed-out one does. Five
	--pages of a thirteen-page search is five pages of real prices, and discarding
	--them because the player stopped waiting is throwing away the work the queries
	--already cost. It matters far more for a full scan, which somebody may well
	--stop halfway through: half the auction house is still half a database.
	scan.stored = A:CommitRecording()

	local handlers = scan.handlers
	if handlers and handlers.complete then
		handlers.complete(scan.results, "cancelled", collected, scan.stored)
	end

	RestoreFirstPage()
end

--name is required; the server will not answer an empty query usefully and the
--result would be "everything", which is neither what anyone meant nor something
--40 pages can hold.
--Shared by both entry points. `full` decides whether rows are kept for a listing
--or folded away, which is the only difference between the two scans.
--[[
	Handlers belong to the SCAN, not to the module.

	They used to be A.OnScanProgress and A.OnScanComplete, set by whichever tab
	built itself last. That works exactly as long as one tab ever scans -- the
	Search tab's own comment said a later tab would have to "swap these for its own
	and put them back", which is a description of a race rather than a design. The
	moment the Sell tab wanted a quiet price check of its own, it would have been
	writing into the Search tab's list and leaving its buttons stuck.

	Passed in per scan, they cannot collide. Only one scan runs at a time either
	way, which is the real constraint, and now that constraint is the only one.
]]
local function Begin(name, minLevel, maxLevel, full, fromPage, handlers)
	scan.results = {}
	scan.name = name
	scan.minLevel = minLevel
	scan.maxLevel = maxLevel
	scan.full = full and true or false
	scan.handlers = handlers
	scan.page = fromPage or 0
	scan.firstPage = scan.page
	scan.total = 0
	scan.collected = 0
	scan.retries = 0
	scan.startedAt = GetTime()
	scan.pagesRead = 0
	scan.cleanPages = 0
	scan.stored = 0
	scan.active = true
	scan.queryPending = true
	scan.awaitingPage = false
	scan.restorePending = false
	scan.nextQuery = 0

	A:BeginRecording()
	Pump():SetScript("OnUpdate", scan.onUpdate)
end

function A:StartScan(name, minLevel, maxLevel, handlers)
	if scan.active then
		self:CancelScan()
		return false
	end

	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	if not name or name == "" then
		E:Print(L["Auction house: type something to search for."])
		return false
	end

	Begin(name, minLevel, maxLevel, false, nil, handlers)
	return true
end

--[[
	Every auction on the realm, into the price database.

	NIL name, not an empty string. A working auction addon on this client builds its
	full-scan query from an empty table, so every filter including the name reaches
	QueryAuctionItems as nil. The first attempt here passed "" instead, on the
	assumption that the two are interchangeable to the server, and the scan came back
	with nothing at all -- no page, no error, no auctions. They are not obviously
	interchangeable and there is no reason to find out the hard way twice.

	No listing is built and none is wanted. The answer to "should I vendor this or list
	it" is a number on a tooltip, not fifteen thousand rows nobody will scroll.
]]
function A:StartFullScan(restart, handlers)
	if scan.active then
		self:CancelScan()
		return false
	end

	if not self:AtAuctionHouse() then
		E:Print(L["Auction house: you are not at an auctioneer."])
		return false
	end

	local from = (not restart) and self.scanResume or nil

	Begin(nil, nil, nil, true, from, handlers)

	local cap = FullScanCap()

	if from then
		E:Print(format(L["AUCTION_FULL_SCAN_RESUME"], from + 1))
	elseif cap then
		E:Print(format(L["AUCTION_FULL_SCAN_START"], cap))
	else
		--No ceiling set, which is the default. There is no number to name.
		E:Print(L["AUCTION_FULL_SCAN_START_ALL"])
	end

	return true
end

--The page a resumed pass would start from, or nil when the last scan finished the
--house. The button reads this to say which of the two it is about to do.
function A:FullScanResumePage()
	return self.scanResume
end

function A:IsFullScan()
	return scan.active and scan.full and true or false
end

--Routed from the module's AUCTION_ITEM_LIST_UPDATE. Only meaningful while a
--page is outstanding; at any other time it is the server answering somebody
--else's query and reading it would mix their page into our results.
function A:AuctionListUpdated()
	if scan.active and scan.awaitingPage then
		scan.pageArrived = true
		CollectPage()
	end
end
