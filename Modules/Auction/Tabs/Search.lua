local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local tonumber, unpack = tonumber, unpack
local format, lower, find = string.format, string.lower, string.find
local getn, tinsert = table.getn, table.insert
local floor, mod = math.floor, math.mod
--WoW API / Variables
local CreateFrame = CreateFrame
local GetItemQualityColor = GetItemQualityColor
local PlaceAuctionBid = PlaceAuctionBid
local GameTooltip = GameTooltip

--[[
	The search tab: type a name, walk every page, list what is out there by price
	per unit.

	PER UNIT IS THE POINT. A seller lists a low bid against a high buyout so the
	row reads cheap in a list sorted on bid, and a stack hides what it really
	costs each -- a 20-stack at 10g is 50s an item and Blizzard's browse list
	will not say so. Both numbers are arithmetic on data the client has already
	handed over, so this costs no extra scanning.

	BUYING GOES THROUGH THE ORIGINAL PAGE. PlaceAuctionBid takes an index into
	the page the server last sent, not into our collected list, so a row cannot
	be bought straight from the results: the page it came from has to be on
	screen again first. Clicking re-queries that page, then bids on the matching
	row once it arrives. Anything else buys whatever happens to be sitting at
	that index now, which is how people buy the wrong auction.
]]

local ROWS = 19

local function QualityColor(entry)
	local r, g, b = GetItemQualityColor(entry.quality or 1)
	return r, g, b
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
	--The whole-stack price: the buyout where there is one, the bid where there is
	--not. Dimmed in the second case, because it is what the auction would cost to
	--WIN rather than what it costs to take now.
	{key = "total", label = L["Total"], width = 17, justify = "RIGHT",
		format = function(v, entry)
			if not v or v <= 0 then return "|cff808080--|r" end
			if entry.buyout > 0 then return A:Money(v) end
			return "|cff9d9d9d"..A:Money(v).."|r"
		end},
	{key = "timeLeft", label = L["Time"], width = 6, justify = "RIGHT",
		format = function(v)
			--1 short, 2 medium, 3 long, 4 very long. The client gives a bucket,
			--not a number, so anything more precise would be invented.
			local text = {"30m", "2h", "8h", "24h"}
			return v and text[v] or ""
		end},
	{key = "owner", label = L["Seller"], width = 12}
}

local function BuildSearch(page)
	local search = CreateFrame("EditBox", "OctoUI_AuctionSearchBox", page)
	E:Size(search, 200, 18)
	E:SetTemplate(search, "Transparent")
	E:Point(search, "TOPLEFT", page, "TOPLEFT", 0, 0)
	search:SetAutoFocus(false)
	search:SetTextInsets(4, 4, 0, 0)
	E:FontTemplate(search, nil, 11, "NONE")

	search.hint = search:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(search.hint, nil, 11, "NONE")
	E:Point(search.hint, "LEFT", search, "LEFT", 5, 0)
	search.hint:SetText(L["Item name..."])
	search.hint:SetTextColor(0.45, 0.45, 0.45)

	search:SetScript("OnTextChanged", function()
		local text = this:GetText()
		if text and text ~= "" then this.hint:Hide() else this.hint:Show() end
	end)
	search:SetScript("OnEscapePressed", function() this:ClearFocus() end)

	return search
end

local function LevelBox(page, label, anchor, x)
	local box = CreateFrame("EditBox", nil, page)
	E:Size(box, 36, 18)
	E:SetTemplate(box, "Transparent")
	E:Point(box, "LEFT", anchor, "RIGHT", x, 0)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetTextInsets(4, 4, 0, 0)
	E:FontTemplate(box, nil, 11, "NONE")
	box:SetScript("OnEscapePressed", function() this:ClearFocus() end)

	box.label = box:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(box.label, nil, 9, "NONE")
	E:Point(box.label, "BOTTOM", box, "TOP", 0, 1)
	box.label:SetText(label)
	box.label:SetTextColor(0.6, 0.6, 0.6)

	return box
end

A.tabBuilders = A.tabBuilders or {}

A.tabBuilders["search"] = function(page)
	local search = BuildSearch(page)
	local minLevel = LevelBox(page, L["Min"], search, 6)
	local maxLevel = LevelBox(page, L["Max"], minLevel, 4)

	local button = CreateFrame("Button", nil, page)
	E:Size(button, 80, 18)
	E:SetTemplate(button, "Transparent")
	E:Point(button, "LEFT", maxLevel, "RIGHT", 6, 0)
	button.text = button:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(button.text, nil, 11, "NONE")
	button.text:SetAllPoints()
	button.text:SetText(L["Search"])
	button:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 1, 1) end)
	button:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)

	--Scanning the whole house is what actually builds the database. It is a
	--separate button rather than "Search with the box empty", because the two do
	--genuinely different things: one fills a list, the other fills the price
	--database and lists nothing.
	local scanAll = CreateFrame("Button", nil, page)
	E:Size(scanAll, 90, 18)
	E:SetTemplate(scanAll, "Transparent")
	E:Point(scanAll, "LEFT", button, "RIGHT", 6, 0)
	scanAll.text = scanAll:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(scanAll.text, nil, 11, "NONE")
	scanAll.text:SetAllPoints()
	scanAll.text:SetText(L["Scan All"])
	scanAll:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Scan All"])
		GameTooltip:AddLine(L["AUCTION_SCAN_ALL_TIP"], 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	scanAll:SetScript("OnLeave", function()
		E:SetTemplate(this, "Transparent")
		GameTooltip:Hide()
	end)

	--[[
		Buying a QUANTITY rather than an auction.

		The auction house sells stacks; people want numbers of things. Typing 47 and
		pressing Buy works out the cheapest set of listings that reaches 47, says
		exactly what that costs and how far over or under it lands, and only then asks.
	]]
	local qtyBox = CreateFrame("EditBox", nil, page)
	E:Size(qtyBox, 44, 18)
	E:SetTemplate(qtyBox, "Transparent")
	E:Point(qtyBox, "LEFT", scanAll, "RIGHT", 14, 0)
	qtyBox:SetAutoFocus(false)
	qtyBox:SetNumeric(true)
	qtyBox:SetTextInsets(3, 3, 0, 0)
	E:FontTemplate(qtyBox, nil, 11, "NONE")
	qtyBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

	qtyBox.label = qtyBox:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(qtyBox.label, nil, 9, "NONE")
	E:Point(qtyBox.label, "BOTTOM", qtyBox, "TOP", 0, 1)
	qtyBox.label:SetText(L["Qty"])
	qtyBox.label:SetTextColor(0.6, 0.6, 0.6)

	local buyButton = CreateFrame("Button", nil, page)
	E:Size(buyButton, 74, 18)
	E:SetTemplate(buyButton, "Transparent")
	E:Point(buyButton, "LEFT", qtyBox, "RIGHT", 6, 0)
	buyButton.text = buyButton:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(buyButton.text, nil, 11, "NONE")
	buyButton.text:SetAllPoints()
	buyButton.text:SetText(L["Buy"])

	local listing = A:CreateListing(page, COLUMNS, ROWS, 740)
	E:Point(listing, "TOPLEFT", page, "TOPLEFT", 0, -26)
	E:Point(listing, "BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	--Cheapest per unit first is the question the tab exists to answer.
	listing.sortColumn = 4
	listing.sortDescending = false

	--Handlers for this tab's own scans, passed to StartScan rather than parked on
	--the module, so the Sell tab's quiet price check cannot land in this list.
	--Declared here rather than beside the functions that fill it further down: Go
	--and GoAll close over it, and a local declared after them would leave those
	--closures reading a global that is nil.
	local handlers = {}

	local function Go(exact)
		if A:IsScanning() then
			A:CancelScan()
			return
		end

		--[[
			The server matches a name as a SUBSTRING, so searching "Solid Stone"
			returns Solid Sharpening Stone and everything else carrying those letters.
			That is right for a typed search, where a partial name is usually the
			point, and wrong for a right-click on an item, where the player has named
			exactly one thing.

			Filtered on the way to the screen, never on the way into the database. The
			near-misses were scanned and their prices are worth keeping whether or not
			this particular list is showing them.
		]]
		if exact then
			local wanted = exact
			listing.filter = function(entry) return entry.name == wanted end
		else
			listing.filter = nil
		end

		local name = search:GetText()
		if A:StartScan(name, tonumber(minLevel:GetText()), tonumber(maxLevel:GetText()), handlers) then
			listing:SetData({})
			button.text:SetText(L["Cancel"])
			A:SetProgress(0, nil, format(L["Searching for %s..."], name))
		end
	end

	local function GoAll()
		if A:IsScanning() then
			A:CancelScan()
			return
		end

		if A:StartFullScan(false, handlers) then
			listing:SetData({})
			scanAll.text:SetText(L["Cancel"])
			--Shown empty the instant the button is pressed. The first page can take a
			--second or two to come back, and a button that visibly does nothing in that
			--window is indistinguishable from one that is broken.
			A:SetProgress(0, nil, L["AUCTION_FULL_SCAN_STATUS"])
		end
	end

	button:SetScript("OnClick", Go)
	scanAll:SetScript("OnClick", GoAll)
	search:SetScript("OnEnterPressed", function()
		this:ClearFocus()
		Go()
	end)

	listing.OnEnter = function(entry, row)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")

		--The real item tooltip where the scan managed to capture a link, so the
		--stats, the level requirement and the stack limit are all there for the
		--decision being made. A link is absent for any row whose item the client
		--had not cached at scan time, which is ordinary on a first search -- hence
		--the hand-built header rather than an empty tooltip.
		if entry.link then
			GameTooltip:SetHyperlink(entry.link)
		else
			GameTooltip:AddLine(entry.name)
		end

		if entry.count > 1 then
			GameTooltip:AddLine(format(L["Stack of %d"], entry.count), 1, 1, 1)
		end
		GameTooltip:AddLine(format(L["Bid %s each"], A:Money(entry.unitBid)), 1, 1, 1)
		if entry.buyout > 0 then
			GameTooltip:AddLine(format(L["Buyout %s each"], A:Money(entry.unitBuyout)), 1, 1, 1)
		end
		if entry.buyout > 0 then
			GameTooltip:AddLine(format(L["AUCTION_SEARCH_CLICK_BUYOUT"], A:Money(entry.buyout)),
				0.6, 0.6, 0.6, 1)
		end
		if entry.nextBid and entry.nextBid > 0 then
			GameTooltip:AddLine(format(L["AUCTION_SEARCH_CLICK_BID"], A:Money(entry.nextBid)),
				0.6, 0.6, 0.6, 1)
		end
		GameTooltip:Show()
	end
	listing.OnLeave = function() GameTooltip:Hide() end

	--Right click bids, left click buys out -- and falls back to bidding where there
	--is no buyout, because otherwise clicking such a row does nothing at all.
	listing.OnClick = function(entry, button)
		local wantsBid = (button == "RightButton") or entry.buyout <= 0

		if wantsBid then
			if not (entry.nextBid and entry.nextBid > 0) then
				E:Print(L["AUCTION_SEARCH_NO_BID"])
				return
			end
			A:BuyEntry(entry, entry.nextBid, true)
			return
		end

		A:BuyEntry(entry, entry.buyout, false)
	end

	E.PopupDialogs["OCTOUI_AUCTION_BULK"] = {
		text = L["AUCTION_BID_CONFIRM"],
		button1 = ACCEPT,
		button2 = CANCEL,
		OnAccept = function()
			local pending = A.pendingBulk
			A.pendingBulk = nil
			if not pending then return end

			A:StartBulkBuy(pending.plan,
				function(index, total)
					A:SetProgress(index - 1, total, format(L["AUCTION_BULK_PROGRESS"], index, total))
				end,
				function(bought, spent, stopped)
					A:HideProgress()
					buyButton.text:SetText(L["Buy"])

					local message = format(stopped and L["AUCTION_BULK_STOPPED"] or L["AUCTION_BULK_DONE"],
						bought, pending.name, A:Money(spent))
					A:SetStatus(message)
					E:Print(message)
				end)
		end,
		OnCancel = function() A.pendingBulk = nil end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1
	}

	local function BuyQuantity()
		if A:IsBulkBuying() then
			A:CancelBulkBuy()
			return
		end

		local wanted = tonumber(qtyBox:GetText())
		if not wanted or wanted < 1 then
			E:Print(L["AUCTION_BULK_NEEDS_QTY"])
			return
		end

		local name = search:GetText()
		if not name or name == "" then
			E:Print(L["Auction house: type something to search for."])
			return
		end

		local plan, count, cost = A:PlanPurchase(listing.data, name, wanted)

		if getn(plan) == 0 then
			E:Print(format(L["AUCTION_BULK_NOTHING"], name))
			return
		end

		A.pendingBulk = {plan = plan, name = name}

		--Says what will actually happen before a copper moves: how many auctions, how
		--many items, and whether that lands over or under what was asked for.
		local shortfall
		if count < wanted then
			shortfall = format(L["AUCTION_BULK_SHORT"], count, wanted)
		elseif count > wanted then
			shortfall = format(L["AUCTION_BULK_OVER"], count, wanted)
		else
			shortfall = format(L["AUCTION_BULK_EXACT"], count)
		end

		E:StaticPopup_Show("OCTOUI_AUCTION_BULK",
			format(L["AUCTION_BULK_SUMMARY"], shortfall, name, getn(plan)),
			format(L["AUCTION_BID_AS_BUYOUT"], A:Money(cost)))
	end

	buyButton:SetScript("OnClick", BuyQuantity)
	buyButton:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Buy"])
		GameTooltip:AddLine(L["AUCTION_BULK_TIP"], 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	buyButton:SetScript("OnLeave", function()
		E:SetTemplate(this, "Transparent")
		GameTooltip:Hide()
	end)

	qtyBox:SetScript("OnEnterPressed", function()
		this:ClearFocus()
		BuyQuantity()
	end)

	page.listing = listing
	page.searchBox = search
	page.button = button
	--Exposed so A:SearchFor can drive the tab from outside it, which is how a
	--right-click on a bag item reaches the search.
	page.Search = Go

	--Set here rather than at module scope so the tab that owns the listing is the
	--one that hears about scans. A later tab scanning for its own reasons swaps
	--these for its own and puts them back.
	--Minutes and seconds, because "743s left" is not an answer anybody wanted.
	local function Remaining(seconds)
		if not seconds or seconds <= 0 then return nil end

		local mins = floor(seconds / 60)
		if mins >= 60 then
			return format(L["AUCTION_ETA_HOURS"], floor(mins / 60), mod(mins, 60))
		end
		if mins >= 1 then return format(L["AUCTION_ETA_MINUTES"], mins) end
		return format(L["AUCTION_ETA_SECONDS"], floor(seconds))
	end

	handlers.progress = function(pageNumber, collected, total, totalPages, eta)
		--Rows appear as their page lands rather than all at the end. A full scan has
		--no rows to show by design, so it is excluded rather than being handed an
		--array it deliberately never fills.
		if not A:IsFullScan() and A.scan and A.scan.results then
			listing:UpdateData(A.scan.results)
		end

		--Pages, not auctions, drive the bar. "Page 3 of 27" is a position somebody can
		--judge how long is left from; "1,240 auctions" is a number with no scale.
		if totalPages and totalPages > 0 then
			local left = Remaining(eta)
			local label

			if left then
				label = format(L["AUCTION_PROGRESS_ETA"], pageNumber, totalPages, collected, left)
			else
				label = format(L["AUCTION_PROGRESS_PAGES"], pageNumber, totalPages, collected)
			end

			A:SetProgress(pageNumber, totalPages, label)
		else
			A:SetProgress(pageNumber, nil, format(L["AUCTION_PROGRESS_STARTING"], pageNumber))
		end
	end

	handlers.complete = function(results, reason, collected, stored)
		--Read before the buttons reset: IsFullScan goes false the moment the scan
		--stops, and both buttons have to come back whichever one started it.
		local full = A.scan and A.scan.full
		stored = stored or 0

		button.text:SetText(L["Search"])
		--Says which of the two the next press does, so a capped scan does not look
		--like a finished one.
		scanAll.text:SetText(A:FullScanResumePage() and L["Scan All (resume)"] or L["Scan All"])
		A:HideProgress()
		listing:SetData(results)

		if full then
			--Nothing at all came back. That is never a real auction house -- an empty
			--realm would still answer with a page saying so -- it means the queries
			--went into a session that is not actually open, which is what a /reload at
			--an auctioneer leaves behind. Say the fix rather than reporting zero and
			--leaving it looking like the feature is broken.
			if collected == 0 then
				A:HideProgress()
				A:SetStatus(L["AUCTION_FULL_SCAN_NO_ANSWER_SHORT"])
				E:Print(L["AUCTION_FULL_SCAN_NO_ANSWER"])
				return
			end

			--The count of items priced is the whole result of a full scan. There is
			--no list to show, and saying "12,431 auctions" answers nothing.
			if reason == "capped" then
				A:SetStatus(format(L["AUCTION_FULL_SCAN_CAPPED"], stored, collected))
			elseif reason == "timeout" then
				A:SetStatus(format(L["AUCTION_FULL_SCAN_PARTIAL"], stored, collected))
			elseif reason == "cancelled" then
				A:SetStatus(format(L["AUCTION_FULL_SCAN_PARTIAL"], stored, collected))
			else
				A:SetStatus(format(L["AUCTION_FULL_SCAN_DONE"], stored, collected))
			end

			E:Print(format(L["AUCTION_FULL_SCAN_DONE"], stored, collected))
			return
		end

		--Just the count. An ordinary search reported how many items it had saved and
		--that their prices would show on tooltips, which is true and is noise: it is
		--the same sentence after every search, about a side effect nobody asked for
		--at that moment. The full scan below still reports its item count, because
		--there the database IS the result rather than a by-product.
		if reason == "timeout" then
			A:SetStatus(format(L["Timed out. %d auctions found."], collected))
		elseif reason == "cancelled" then
			A:SetStatus(format(L["Cancelled. %d auctions found."], collected))
		else
			A:SetStatus(format(L["%d auctions found."], collected))
		end
	end
end

--[[
	Search for one named item, exactly.

	Reached from a right-click on a bag item while the window is open. Selects the
	tab first, which also builds it: the player may never have opened Search this
	session, and a right-click that silently did nothing because a tab had not been
	visited yet would be indistinguishable from the feature being broken.
]]
function A:SearchFor(name)
	if not (name and name ~= "") then return false end
	if not self.window then return false end

	self:SelectTab("search")

	local page = self.window.tabs and self.window.tabs["search"]
	if not (page and page.searchBox and page.Search) then return false end

	page.searchBox:SetText(name)
	page.searchBox:ClearFocus()
	page.Search(name)
	return true
end
