local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local format = string.format
local ceil, floor = math.ceil, math.floor
local getn, tinsert, tsort = table.getn, table.insert, table.sort
local pairs, tonumber, type = pairs, tonumber, type
local time = time
--WoW API / Variables
local CreateFrame = CreateFrame
local GetAuctionItemInfo = GetAuctionItemInfo
local GetAuctionItemTimeLeft = GetAuctionItemTimeLeft
local GetItemQualityColor = GetItemQualityColor
local GetNumAuctionItems = GetNumAuctionItems
local GetTime = GetTime
local CanSendAuctionQuery = CanSendAuctionQuery
local QueryAuctionItems = QueryAuctionItems
local FauxScrollFrame_GetOffset = FauxScrollFrame_GetOffset
local IsAddOnLoaded = IsAddOnLoaded
local HookScript = HookScript
local hooksecurefunc = hooksecurefunc

--[[
	Auction house browse list: price per unit, and a marker for auctions with no buyout.

	Open item 19, build step 1. Sellers list a low bid against a high buyout so the row
	reads cheap in a list sorted on bid, and a stack hides what it really costs per item --
	a 20-stack at 10g is 50s each and the browse list will not say so. Both are arithmetic
	on data the client has already handed over, so this needs no scanning and no storage.

	GetAuctionItemInfo("list", index) answers
	    name, texture, count, quality, canUse, level, minBid, minIncrement,
	    buyoutPrice, bidAmount, highBidder, owner
	and count with buyoutPrice is the whole feature. Measured present on this client on
	2026-08-06 (/oprobe api, auction group) along with the eleven other auction functions
	the rest of item 19 needs.

	Each row reads "<bid per unit> / <buyout per unit> ea", the two questions a buyer
	actually has, side by side. The cheaper of each column for that item name is drawn
	green. An auction with no buyout says so instead of quietly showing nothing, because
	a blank buyout is exactly what makes a low bid look like a bargain.

	The row annotation covers THIS PAGE ONLY. The auction house hands over one page at a
	time and the client holds no more than that, so "cheapest" on a row means cheapest of
	what is on screen. It is tracked per item NAME rather than across the whole page --
	comparing a per-unit price for Copper Ore against one for Copper Bar is meaningless,
	and a name search returns both.

	Making it true across a whole search is the Scan button further down, which walks every
	page of one search and sorts the lot on price per unit. That half has its own block
	comment at the top of it.

	Nothing in this file posts an auction or spends a copper. The scan is the only thing
	that talks to the server at all, and every query it sends is gated.
]]

--[[
	Where the per-unit text goes, and how that was settled.

	It was under the item name to begin with, and that was wrong in a way worth recording.
	A browse row is two lines tall -- the name on the first, the Buyout amount on the
	second -- so a line hung under the name lands at the bottom of its own row's band,
	NEARER THE NEXT ROW'S NAME THAN ITS OWN. Both of the first two reports against this
	feature were that same misreading, and neither reporter was being careless: "19c ea,
	no buyout" drawn directly above an auction that plainly has a buyout reads as a bug,
	and the numbers were right the whole time. **A row annotation must be unambiguous
	about which row it annotates, and vertical proximity does not establish that.**

	It then went after the name text, measured with GetStringWidth. That fixed the
	ambiguity and was still a guess about the space available.

	MEASURED 2026-08-06 with /oprobe kids BrowseButton1, offsets from the row's own left:

	    Item (icon)            0 .. 32
	    Name                  43 .. 210   (a fixed 167-wide column, 32 tall)
	    Level                205 .. 257
	    ClosingTime          267 .. 332
	    HighBidder (seller)  345 .. 423
	    -- nothing at all --  423 .. 517
	    BuyoutText           517
	    BuyoutMoneyFrame     532 .. 610
	    MoneyFrame (bid)     539 .. 610

	So the name column ENDS at 210 and the level column STARTS at 205: they overlap, and
	there is no slack after a long name at all.

	**BuyoutText's box is not the Buyout label.** The probe reports it as a Button 10 wide
	at +517, and the word it draws is roughly four times that and spills LEFT of the box.
	Anchoring at 510 -- "7px clear of the button" -- put the per-unit text straight through
	the word. That is the same mistake twice in one feature: measuring the widget instead
	of what the widget draws. So the right-hand bound is now taken from the label's own
	FONT STRING at runtime, and only falls back to a constant when the frame has not been
	laid out yet.

	This still occupies leftover space rather than space that was made for it, which is
	the real criticism and is answered separately: the browse row's own columns want
	re-laying out to carry a proper per-unit column with a heading, rather than a fourth
	thing wedged into the gaps between three others.

	Vertically it anchors to the NAME region, not to the row button. The button measures
	13 tall while Name is 32 and the icon overflows both, so the button's centre is not the
	row's centre -- anchoring there would sit the text above the name rather than beside it.
]]
--[[
	PARKED 2026-08-06, at the user's request, to be picked up later.

	Everything in this file stays exactly as written. This one switch is what turns it back
	on: with it false, M:LoadAuctionHouse returns immediately, so nothing hooks
	AuctionFrameBrowse_Update, no event is registered, no Scan button is built and no font
	string is created. The tooltip half is parked by the matching switch at
	TT:SetAuctionPrice in Modules/Tooltip/Tooltip.lua, and both options are hidden from
	the config tree rather than left as toggles that do nothing.

	Why it was parked rather than finished: the per-unit text is wedged into whatever gaps
	Blizzard's browse row leaves between its existing columns, and that is the wrong shape.
	The row wants re-laying out to carry a real per-unit column with a heading. See open
	item 19 in HANDOFF.md for the measured geometry and what that work involves.

	`G["auctionPrices"]` in Settings/Global.lua is left in place. It is defaults-only until
	a scan runs, so it costs nothing while this is off, and removing it would discard any
	prices already collected.
]]
local ENABLED = false

--Fallbacks only, for the window that has never been laid out. Everything real is measured.
local NAME_LEFT_FALLBACK = 43
local TEXT_RIGHT_FALLBACK = 470
local TEXT_GAP = 8
local TEXT_SIZE = 10

--Measured once the auction house has drawn, then cached. GetLeft answers nil for a frame
--that is hidden or not yet laid out, so this returns nil until it can be trusted rather
--than defaulting the difference to zero.
local geom = nil

local function Geometry()
	if geom then return geom end

	local row = _G.BrowseButton1
	local rowLeft = row and row.GetLeft and row:GetLeft()
	if not rowLeft then return nil end

	local name = _G.BrowseButton1Name
	local nameLeft = name and name:GetLeft()
	if not nameLeft then return nil end

	--The leftmost edge of anything the Buyout label actually draws. GetFontString covers
	--the ordinary case; the region walk covers a label whose text is not the button's own
	--font string, which is exactly the shape that caused the overlap.
	local label = _G.BrowseButton1BuyoutText
	local edge = nil

	if label then
		if label.GetFontString then
			local labelText = label:GetFontString()
			if labelText and labelText.GetLeft then edge = labelText:GetLeft() end
		end

		if label.GetRegions then
			local regions = {label:GetRegions()}
			for r = 1, getn(regions) do
				local region = regions[r]
				if region and region.GetObjectType and region:GetObjectType() == "FontString" then
					local left = region:GetLeft()
					if left and (not edge or left < edge) then edge = left end
				end
			end
		end

		if not edge then edge = label:GetLeft() end
	end

	if not edge then return nil end

	geom = {nameLeft = nameLeft - rowLeft, columnRight = (edge - rowLeft) - TEXT_GAP}
	return geom
end

local GREEN, GREY, ORANGE = "|cff00ff00", "|cffa0a0a0", "|cffff8000"
local MARKER = "|cffffff00>>|r "

--The auction the results window last sent the browse list to, kept so the row it lands on
--can be pointed at. Matched on the auction's own fields rather than on an index, because
--an index only means anything on the page it came from and the user can page away and
--back. Nothing here selects the auction -- see the note on JumpToEntry for why not.
local markedAuction = nil

--Row state, rebuilt on every update. Filled by index rather than by tinsert, so nothing
--here may ask getn how big it is -- the row count is NUM_BROWSE_TO_DISPLAY and is known.
local unitText = {}
local rowName, rowBid, rowBuyout, rowMarked = {}, {}, {}, {}
local cheapestBid, cheapestBuyout = {}, {}
--Set once if a row's own item name matched neither candidate index, so the warning is
--said once per session rather than on every redraw of the list.
local warnedIndex = false
--How many rows on this page are that item, and how many of those carry a buyout. Green
--means "cheaper than the others", so it is only worth drawing where there ARE others --
--otherwise the single result for a name is trivially its own cheapest and every row on
--an eight-different-items page lights up.
local nameRows, nameBuyoutRows = {}, {}

local function RowFontString(i)
	if unitText[i] then return unitText[i] end

	local button = _G["BrowseButton"..i]
	if not button then return nil end

	local fs = button:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(fs, nil, TEXT_SIZE, "OUTLINE")
	fs:SetJustifyH("RIGHT")

	unitText[i] = fs
	return fs
end

--Re-applied rather than set once at creation, because the measurement is not available
--until the auction house has been laid out and the font strings can be created before
--that. Once Geometry answers, the anchor stops changing and this is one comparison.
local function AnchorRowText(fs, i)
	local measured = Geometry()
	local right = measured and measured.columnRight or TEXT_RIGHT_FALLBACK
	local nameLeft = measured and measured.nameLeft or NAME_LEFT_FALLBACK

	if fs.anchoredAt == right then return end
	fs.anchoredAt = right

	fs:ClearAllPoints()

	local name = _G["BrowseButton"..i.."Name"]
	if name then
		fs:SetPoint("RIGHT", name, "LEFT", right - nameLeft, 0)
	else
		--No name region to take the vertical from. Wrong height, right column, and visible
		--either way -- which makes a broken assumption reportable rather than silent.
		fs:SetPoint("RIGHT", _G["BrowseButton"..i], "LEFT", right, 0)
	end
end

--Which auction a row is showing, and whether that answer can be trusted.
--
--The row's own ID is the client's authority: BrowseButton_OnClick reads it to call
--SetSelectedAuctionItem, so a wrong ID would break clicking, not merely this. Recomputing
--it from the scroll offset is the usual approach and is a SECOND source of truth that can
--disagree with the first, so the name the row is already displaying is the tie-breaker.
--
--When neither agrees, the ID is still used -- but the second return says so, and the
--caller says it out loud once. A per-unit price lined up against the wrong auction is a
--worse failure than no price at all, and it is the sort that would never announce itself.
local function ResolveIndex(button, i, offset)
	local label = _G["BrowseButton"..i.."Name"]
	local shown = label and label:GetText()
	if shown == "" then shown = nil end

	local id = button.GetID and button:GetID()
	if id and id < 1 then id = nil end
	local alt = offset + i

	local idName = id and GetAuctionItemInfo("list", id)
	local altName = GetAuctionItemInfo("list", alt)

	if shown then
		if idName == shown then return id, true end
		if altName == shown then return alt, true end
	end

	--Nothing to check against, or neither matched. Trusted only in the first case.
	if idName then return id, (shown == nil) end
	if altName then return alt, (shown == nil) end
	return nil
end

local function UpdateBrowseRows()
	local enabled = E.db.general.auctionUnitPrice
	local rows = NUM_BROWSE_TO_DISPLAY or 8
	local offset = 0
	if FauxScrollFrame_GetOffset and _G.BrowseScrollFrame then
		offset = FauxScrollFrame_GetOffset(_G.BrowseScrollFrame) or 0
	end

	for k in pairs(cheapestBid) do cheapestBid[k] = nil end
	for k in pairs(cheapestBuyout) do cheapestBuyout[k] = nil end
	for k in pairs(nameRows) do nameRows[k] = nil end
	for k in pairs(nameBuyoutRows) do nameBuyoutRows[k] = nil end

	--Read the page first, and only then colour it: the cheapest of a column is not known
	--until every row has been seen.
	local mismatched = false

	for i = 1, rows do
		rowName[i], rowBid[i], rowBuyout[i], rowMarked[i] = nil, nil, nil, nil

		local button = enabled and _G["BrowseButton"..i]
		if button and button:IsShown() then
			local index, trusted = ResolveIndex(button, i, offset)
			if index then
				if not trusted then mismatched = true end
				local name, _, count, _, _, _, minBid, _, buyoutPrice, bidAmount, _, owner = GetAuctionItemInfo("list", index)
				if name and count and count > 0 then
					--What a buyer would have to put up right now, which is what the row's
					--own money frame shows: the standing bid if there is one, else the
					--starting bid. Not bid + increment, deliberately -- that is what it
					--costs to WIN, and it is not the number next to it on screen.
					local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
					local buyout = buyoutPrice or 0

					rowName[i] = name
					rowBid[i] = floor((bid / count) + 0.5)
					rowBuyout[i] = (buyout > 0) and floor((buyout / count) + 0.5) or 0

					nameRows[name] = (nameRows[name] or 0) + 1
					if not cheapestBid[name] or rowBid[i] < cheapestBid[name] then
						cheapestBid[name] = rowBid[i]
					end
					if rowBuyout[i] > 0 then
						nameBuyoutRows[name] = (nameBuyoutRows[name] or 0) + 1
						if not cheapestBuyout[name] or rowBuyout[i] < cheapestBuyout[name] then
							cheapestBuyout[name] = rowBuyout[i]
						end
					end

					--All five fields, because four of them collide constantly: a search for
					--Linen Cloth returns dozens of 20-stacks at the same price from the same
					--seller, and pointing at the wrong one of those defeats the point.
					if markedAuction and markedAuction.name == name and markedAuction.count == count
						and markedAuction.minBid == (minBid or 0) and markedAuction.buyout == buyout
						and markedAuction.owner == owner then
						rowMarked[i] = true
					end
				end
			end
		end
	end

	if mismatched and not warnedIndex then
		warnedIndex = true
		E:Print(L["Auction house: a browse row's item name matched neither auction index, so per-unit prices may be against the wrong row. Please report this."])
	end

	for i = 1, rows do
		--Only reach for the font string if there is something to say, or if one already
		--exists and has to be cleared. Turning the feature off should not leave stale
		--prices on screen, and should not create widgets either.
		local fs = unitText[i]
		if enabled and rowName[i] and not fs then fs = RowFontString(i) end

		if fs then
			if not (enabled and rowName[i]) then
				fs:SetText("")
			else
				AnchorRowText(fs, i)
				local name = rowName[i]
				local bidColor = ((nameRows[name] or 0) > 1 and rowBid[i] == cheapestBid[name]) and GREEN or GREY
				local mark = rowMarked[i] and MARKER or ""

				if rowBuyout[i] > 0 then
					local buyoutColor = ((nameBuyoutRows[name] or 0) > 1 and rowBuyout[i] == cheapestBuyout[name]) and GREEN or GREY
					fs:SetText(mark..format(L["AUCTION_UNIT_PRICE"],
						bidColor..E:FormatMoney(rowBid[i], "SMART").."|r",
						buyoutColor..E:FormatMoney(rowBuyout[i], "SMART").."|r"))
				else
					fs:SetText(mark..format(L["AUCTION_UNIT_PRICE_NO_BUYOUT"],
						bidColor..E:FormatMoney(rowBid[i], "SMART").."|r",
						ORANGE..L["no buyout"].."|r"))
				end
			end
		end
	end
end

--[[
	Step 2: a paged scan of ONE search, and its results sorted on price per unit.

	Why this exists at all. The browse list holds one page, so "cheapest per unit" on the
	page above is only ever cheapest of what is on screen, and a per-unit sort cannot be
	asked of the server -- SortAuctionItems knows bid, buyout, level, duration and seller,
	and nothing about what a stack works out at each. The only way to answer the question
	is to hold every page at once, which means walking them.

	Bounded on purpose: it scans the search already typed into the box, and refuses with an
	empty one. Walking every auction on the realm is what Auctioneer is; see item 19.

	Throttling is not optional. Every query waits on CanSendAuctionQuery AND on an interval
	of its own, because the two guard different things -- the client's gate answers "will
	this be accepted", not "is this a sensible rate". Ignoring either is how an addon gets
	a player disconnected. The scan also gives up if a page never arrives, rather than
	sitting on a dead handler forever.

	The results are shown in OUR OWN window, deliberately. The obvious alternative is to
	reorder the real browse list into per-unit order by rewriting each row -- and that
	means rewriting each row's ID, which is what BrowseButton_OnClick hands to
	SetSelectedAuctionItem. Getting that wrong once means bidding on an auction the player
	did not click. A read-only window cannot spend anyone's gold, so it is the only version
	of this worth shipping.
]]

local SCAN_INTERVAL = 0.4   --seconds between queries, on top of CanSendAuctionQuery
local SCAN_TIMEOUT = 15     --give up if a page never arrives
local SCAN_MAX_PAGES = 40   --hard stop, ~2000 auctions of one search
local RESULT_ROWS = 16
local INFINITE = 1e18       --sorts "no buyout" last: an absent buyout is not a cheap one

local scan = {results = {}}
local scanButton, resultsFrame
local sortMode = "unitBuyout"

--What the window is actually showing: scan.results with the filter applied, then sorted.
--Kept separate from the raw results so switching the filter off does not need a rescan.
local view = {}
local buyoutOnly = false

--Sending the browse list to one scanned auction. Nothing about this is a scan, so it gets
--its own state rather than borrowing the scan's -- the two can never run at once but
--sharing the flags would make that a rule someone has to remember rather than one the code
--enforces.
local jump = {}

local function ScanFieldsFromUI()
	local name = _G.BrowseName and _G.BrowseName:GetText() or ""
	local minLevel = _G.BrowseMinLevel and tonumber(_G.BrowseMinLevel:GetText())
	local maxLevel = _G.BrowseMaxLevel and tonumber(_G.BrowseMaxLevel:GetText())
	return name, minLevel, maxLevel
end

local function CompareResults(a, b)
	if sortMode == "unitBid" then
		if a.unitBid ~= b.unitBid then return a.unitBid < b.unitBid end
		return a.unitBuyout < b.unitBuyout
	end

	local av = (a.buyout > 0) and a.buyout or INFINITE
	local bv = (b.buyout > 0) and b.buyout or INFINITE
	if sortMode == "totalBuyout" then
		if av ~= bv then return av < bv end
		return a.unitBuyout < b.unitBuyout
	end

	--unitBuyout, the default and the whole point of the exercise
	av = (a.unitBuyout > 0) and a.unitBuyout or INFINITE
	bv = (b.unitBuyout > 0) and b.unitBuyout or INFINITE
	if av ~= bv then return av < bv end
	return a.unitBid < b.unitBid
end

--Apply the filter, then sort what survives.
--
--"Buyout only" is not cosmetic: an auction with no buyout cannot be bought, only bid on
--and waited for, so for anyone who needs the item now those rows are noise dressed up as
--the cheapest option. Sorting them last is not enough at thirteen pages -- they still
--occupy the list. Off by default, because hiding results nobody asked to hide is worse
--than showing a few that do not apply.
local function RebuildView()
	view = {}
	for i = 1, getn(scan.results) do
		local entry = scan.results[i]
		if entry.buyout > 0 or not buyoutOnly then
			tinsert(view, entry)
		end
	end

	--Filled by tinsert, so getn reports what is actually there. See the note at the top of
	--HANDOFF about tables filled by index, which this deliberately is not.
	if getn(view) > 1 then tsort(view, CompareResults) end
end

local function UpdateResultsPage()
	if not resultsFrame then return end

	local total = getn(view)
	local pages = ceil(total / RESULT_ROWS)
	if pages < 1 then pages = 1 end
	if resultsFrame.page > pages then resultsFrame.page = pages end
	if resultsFrame.page < 1 then resultsFrame.page = 1 end

	local offset = (resultsFrame.page - 1) * RESULT_ROWS

	for i = 1, RESULT_ROWS do
		local row = resultsFrame.rows[i]
		local entry = view[offset + i]
		row.entry = entry

		if entry then
			local r, g, b = GetItemQualityColor(entry.quality or 1)
			row.item:SetText(entry.name)
			row.item:SetTextColor(r, g, b)
			row.rank:SetText(offset + i)
			row.qty:SetText(entry.count)
			row.unitBid:SetText(E:FormatMoney(entry.unitBid, "SMART"))
			if entry.buyout > 0 then
				row.unitBuyout:SetText(E:FormatMoney(entry.unitBuyout, "SMART"))
				row.buyout:SetText(E:FormatMoney(entry.buyout, "SMART"))
			else
				row.unitBuyout:SetText(ORANGE..L["no buyout"].."|r")
				row.buyout:SetText("")
			end
			row.seller:SetText(entry.owner or "")
			row.timeLeft:SetText(entry.timeText or "")
			row:Show()
		else
			row:Hide()
		end
	end

	resultsFrame.pageText:SetText(format(L["Page %d / %d"], resultsFrame.page, pages))
	resultsFrame.title:SetText(format(L["AUCTION_SCAN_TITLE"], scan.name or "", total))

	--Highlight whichever sort is live, so the window says what it is showing rather than
	--leaving it to be inferred from the numbers.
	resultsFrame.sortUnitBuyout:SetAlpha(sortMode == "unitBuyout" and 1 or 0.5)
	resultsFrame.sortUnitBid:SetAlpha(sortMode == "unitBid" and 1 or 0.5)
	resultsFrame.sortTotalBuyout:SetAlpha(sortMode == "totalBuyout" and 1 or 0.5)
	resultsFrame.buyoutOnly:SetAlpha(buyoutOnly and 1 or 0.5)

	--The headline, recomputed from what is on show rather than from the raw scan: with the
	--filter on, "cheapest" has to mean cheapest of the ones that can actually be bought.
	local best = nil
	for i = 1, total do
		local entry = view[i]
		if entry.buyout > 0 and (not best or entry.unitBuyout < best.unitBuyout) then
			best = entry
		end
	end

	if best then
		resultsFrame.note:SetText(format(L["AUCTION_SCAN_CHEAPEST"],
			E:FormatMoney(best.unitBuyout, "SMART"), best.count,
			E:FormatMoney(best.buyout, "SMART"), best.owner or "?"))
	elseif total > 0 then
		resultsFrame.note:SetText(L["Not one of these auctions has a buyout."])
	else
		resultsFrame.note:SetText("")
	end
end

local function ApplyView(resetPage)
	RebuildView()
	if resultsFrame and resetPage then resultsFrame.page = 1 end
	UpdateResultsPage()
end

local function SetSortMode(mode)
	sortMode = mode
	ApplyView(true)
end

local function SetBuyoutOnly(value)
	buyoutOnly = value
	ApplyView(true)
end

--[[
	Sending the browse list to one scanned auction.

	This is what makes the scan worth running. Knowing the cheapest is 16c each from
	Twotwoone is no use across thirteen pages if finding it again means paging by hand and
	hoping -- at which point the whole thing is trivia rather than a tool.

	Clicking a result re-queries the page it came from, finds the auction again by its own
	fields, scrolls the browse list so it is the top visible row, and marks it. Then it
	stops.

	**It deliberately does NOT select the auction.** SetSelectedAuctionItem is what the Bid
	and Buyout buttons act on, so selecting for the user means that if the match were ever
	subtly wrong, their next click spends gold on something they did not choose. Taking
	them to the row and pointing at it costs one more click and cannot do that. It also
	needs no API beyond the twelve already measured -- SetSelectedAuctionItem has never
	been probed on this client.

	The auction is matched on name, count, minBid, buyout AND owner. Four of those collide
	constantly: a Linen Cloth search returns dozens of 20-stacks at the same price from the
	same seller. If no exact match survives on that page the auction has sold or expired,
	and it says so rather than pointing at whatever is nearest.
]]
local function EntryMatches(entry, name, count, minBid, buyout, owner)
	return entry.name == name and entry.count == count and entry.minBid == (minBid or 0)
		and entry.buyout == (buyout or 0) and entry.owner == owner
end

local function ScrollBrowseTo(index)
	local rows = NUM_BROWSE_TO_DISPLAY or 8
	local batch = GetNumAuctionItems("list") or 0

	local offset = index - 1
	local maxOffset = batch - rows
	if maxOffset < 0 then maxOffset = 0 end
	if offset > maxOffset then offset = maxOffset end
	if offset < 0 then offset = 0 end

	--Driving the scroll bar rather than the faux scroll frame directly: its OnValueChanged
	--is what sets the offset AND moves the visible thumb, so the list and the bar cannot
	--end up disagreeing. FauxScrollFrame_SetOffset is the fallback, because it has never
	--been confirmed on this client.
	--
	--The step comes from the bar's OWN range, not from a row's height. That was the first
	--version and it was wrong: /oprobe kids BrowseButton1 reports the button at 13 tall
	--against a row pitch of roughly 36, with a 32px icon child overflowing it, so the
	--button is not the row and its height is not the pitch. Deriving the step removes the
	--question rather than answering it.
	local scrolled = false
	local bar = _G.BrowseScrollFrameScrollBar
	local scrollable = batch - rows

	if bar and scrollable > 0 then
		local _, maxValue = bar:GetMinMaxValues()
		if maxValue and maxValue > 0 then
			bar:SetValue(offset * (maxValue / scrollable))
			scrolled = true
		end
	end

	if not scrolled and offset > 0 and type(_G.FauxScrollFrame_SetOffset) == "function" and _G.BrowseScrollFrame then
		FauxScrollFrame_SetOffset(_G.BrowseScrollFrame, offset)
	end

	return (index - offset)
end

local function FinishJump()
	local entry = jump.entry
	jump.active = false
	jump.awaitingPage = false
	jump.entry = nil

	local batch = GetNumAuctionItems("list") or 0
	for i = 1, batch do
		local name, _, count, _, _, _, minBid, _, buyoutPrice, _, _, owner = GetAuctionItemInfo("list", i)
		if name and count and EntryMatches(entry, name, count, minBid, buyoutPrice, owner) then
			markedAuction = entry
			local visibleRow = ScrollBrowseTo(i)

			--Keep Blizzard's own page counter honest. Only touched when it is already a
			--number: inventing the field would leave the Next/Prev buttons paging from a
			--position the client never set.
			if _G.AuctionFrameBrowse and type(_G.AuctionFrameBrowse.page) == "number" then
				_G.AuctionFrameBrowse.page = entry.page
			end

			if type(_G.AuctionFrameBrowse_Update) == "function" then
				AuctionFrameBrowse_Update()
			end

			E:Print(format(L["AUCTION_JUMP_FOUND"], entry.page + 1, visibleRow))
			return
		end
	end

	markedAuction = nil
	E:Print(L["AUCTION_JUMP_GONE"])
end

local function JumpToEntry(entry)
	if not entry then return end
	if scan.active then return end

	if not (_G.AuctionFrame and _G.AuctionFrame:IsShown()) then
		E:Print(L["AUCTION_JUMP_NEEDS_AH"])
		return
	end

	jump.entry = entry
	jump.active = true
	jump.queryPending = true
	jump.awaitingPage = false
	jump.nextQuery = 0

	--A jump supersedes the end-of-scan restore: both exist to put the browse list
	--somewhere, and leaving the flag set strands it for the rest of the session because
	--the jump branch of the pump runs first and never falls through to it.
	scan.restorePending = false

	scan.frame:SetScript("OnUpdate", scan.onUpdate)
end

--One table drives the headers and the row font strings both, so a column cannot drift
--away from the heading that names it.
local COLUMNS = {
	{key = "rank",       x = 10,  w = 24,  justify = "RIGHT", header = "#"},
	{key = "item",       x = 40,  w = 136, justify = "LEFT",  header = L["Item"]},
	{key = "qty",        x = 180, w = 28,  justify = "RIGHT", header = L["Qty"]},
	{key = "unitBid",    x = 212, w = 68,  justify = "RIGHT", header = L["Bid ea"]},
	{key = "unitBuyout", x = 284, w = 72,  justify = "RIGHT", header = L["Buyout ea"]},
	{key = "buyout",     x = 360, w = 76,  justify = "RIGHT", header = L["Buyout"]},
	{key = "seller",     x = 442, w = 94,  justify = "LEFT",  header = L["Seller"]},
	{key = "timeLeft",   x = 540, w = 66,  justify = "LEFT",  header = L["Time"]}
}

local function BuildResultsFrame()
	if resultsFrame then return end

	local f = CreateFrame("Frame", "ElvUI_AuctionScanFrame", UIParent)
	E:SetTemplate(f, "Transparent")
	--76 of header (title, note, sort row, column headings), the rows, then 32 for the
	--paging row. Derived rather than typed so changing RESULT_ROWS cannot leave the page
	--buttons drawn over the last result.
	E:Width(f, 620)
	E:Height(f, 76 + (RESULT_ROWS * 16) + 32)
	E:Point(f, "CENTER", UIParent, "CENTER", 0, 0)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function() this:StartMoving() end)
	f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	f:Hide()

	f.page = 1
	f.rows = {}

	f.title = f:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(f.title, nil, 13, "OUTLINE")
	E:Point(f.title, "TOPLEFT", f, "TOPLEFT", 10, -9)

	f.note = f:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(f.note, nil, 10)
	f.note:SetTextColor(0.7, 0.7, 0.7)
	E:Point(f.note, "TOPLEFT", f, "TOPLEFT", 10, -25)

	local close = CreateFrame("Button", "ElvUI_AuctionScanFrameCloseButton", f, "UIPanelCloseButton")
	E:Point(close, "TOPRIGHT", f, "TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() f:Hide() end)

	--Named, because S:HandleButton reaches the UIPanelButtonTemplate's own Left/Middle/Right
	--textures through _G[name.."Left"] and cannot kill what it cannot name -- an unnamed
	--button keeps Blizzard's gold edges under OctoUI's backdrop.
	local function SortButton(name, label, mode, anchorTo)
		local b = CreateFrame("Button", name, f, "UIPanelButtonTemplate")
		E:Width(b, 96)
		E:Height(b, 18)
		b:SetText(label)
		if anchorTo then
			E:Point(b, "LEFT", anchorTo, "RIGHT", 4, 0)
		else
			E:Point(b, "TOPLEFT", f, "TOPLEFT", 10, -40)
		end
		b:SetScript("OnClick", function() SetSortMode(mode) end)
		return b
	end

	f.sortUnitBuyout = SortButton("ElvUI_AuctionScanSortUnitBuyout", L["Buyout ea"], "unitBuyout", nil)
	f.sortUnitBid = SortButton("ElvUI_AuctionScanSortUnitBid", L["Bid ea"], "unitBid", f.sortUnitBuyout)
	f.sortTotalBuyout = SortButton("ElvUI_AuctionScanSortTotalBuyout", L["Total buyout"], "totalBuyout", f.sortUnitBid)

	f.buyoutOnly = CreateFrame("Button", "ElvUI_AuctionScanBuyoutOnly", f, "UIPanelButtonTemplate")
	E:Width(f.buyoutOnly, 110)
	E:Height(f.buyoutOnly, 18)
	f.buyoutOnly:SetText(L["Buyout only"])
	E:Point(f.buyoutOnly, "LEFT", f.sortTotalBuyout, "RIGHT", 12, 0)
	f.buyoutOnly:SetScript("OnClick", function() SetBuyoutOnly(not buyoutOnly) end)

	f.hint = f:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(f.hint, nil, 10)
	f.hint:SetTextColor(0.55, 0.55, 0.55)
	f.hint:SetJustifyH("RIGHT")
	E:Point(f.hint, "BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 14)
	f.hint:SetText(L["Click a row to take the browse list to it."])

	for c = 1, getn(COLUMNS) do
		local col = COLUMNS[c]
		local head = f:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(head, nil, 10, "OUTLINE")
		head:SetTextColor(1, 0.8, 0.1)
		head:SetJustifyH(col.justify)
		E:Width(head, col.w)
		E:Point(head, "TOPLEFT", f, "TOPLEFT", col.x, -62)
		head:SetText(col.header)
	end

	for i = 1, RESULT_ROWS do
		local row = CreateFrame("Button", nil, f)
		E:Width(row, 600)
		E:Height(row, 16)
		E:Point(row, "TOPLEFT", f, "TOPLEFT", 0, -76 - ((i - 1) * 16))

		--Same idiom as E:StyleButton: a flat colour texture rather than a file, set as the
		--highlight object. Not E:StyleButton itself, which would also add a pushed and a
		--checked texture this row has no use for.
		local highlight = row:CreateTexture()
		highlight:SetTexture(1, 1, 1, 0.15)
		E:SetInside(highlight)
		row:SetHighlightTexture(highlight)

		--row.entry is set by UpdateResultsPage, so a row that is showing nothing sends
		--nothing anywhere.
		row:SetScript("OnClick", function() JumpToEntry(this.entry) end)

		for c = 1, getn(COLUMNS) do
			local col = COLUMNS[c]
			local fs = row:CreateFontString(nil, "OVERLAY")
			E:FontTemplate(fs, nil, 11)
			fs:SetJustifyH(col.justify)
			E:Width(fs, col.w)
			E:Point(fs, "LEFT", row, "LEFT", col.x, 0)
			row[col.key] = fs
		end

		f.rows[i] = row
	end

	local prevButton = CreateFrame("Button", "ElvUI_AuctionScanPrevButton", f, "UIPanelButtonTemplate")
	E:Width(prevButton, 60)
	E:Height(prevButton, 20)
	prevButton:SetText("<")
	E:Point(prevButton, "BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
	prevButton:SetScript("OnClick", function() f.page = f.page - 1 UpdateResultsPage() end)

	local nextButton = CreateFrame("Button", "ElvUI_AuctionScanNextButton", f, "UIPanelButtonTemplate")
	E:Width(nextButton, 60)
	E:Height(nextButton, 20)
	nextButton:SetText(">")
	E:Point(nextButton, "BOTTOMLEFT", prevButton, "BOTTOMRIGHT", 4, 0)
	nextButton:SetScript("OnClick", function() f.page = f.page + 1 UpdateResultsPage() end)

	f.pageText = f:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(f.pageText, nil, 11)
	E:Point(f.pageText, "LEFT", nextButton, "RIGHT", 8, 0)

	local skins = E:GetModule("Skins", true)
	if skins and skins.HandleButton then
		skins:HandleButton(f.sortUnitBuyout)
		skins:HandleButton(f.sortUnitBid)
		skins:HandleButton(f.sortTotalBuyout)
		skins:HandleButton(f.buyoutOnly)
		skins:HandleButton(prevButton)
		skins:HandleButton(nextButton)
		if skins.HandleCloseButton then skins:HandleCloseButton(close) end
	end

	resultsFrame = f
	M.AuctionScanFrame = f
end

--What the scan learned, kept per item name and per account. One record, not a history:
--the cheapest per unit seen and when, which is enough to answer "is this dear today"
--without becoming a price database in its own right.
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

local function StopScanning()
	scan.active = false
	scan.queryPending = false
	scan.awaitingPage = false
	if scan.frame then scan.frame:SetScript("OnUpdate", nil) end
	if scanButton then
		scanButton:SetText(L["Scan"])
		scanButton:Enable()
	end
end

--Put the browse list back on the first page of the user's own search. A scan ends wherever
--the last page was, and leaving them staring at page nine looks exactly like the search
--broke. Gated like every other query, so it queues rather than fires.
local function RestoreFirstPage()
	if not scan.name or scan.name == "" then return end
	scan.restorePending = true
	scan.frame:SetScript("OnUpdate", scan.onUpdate)
end

local function FinishScan()
	local collected = getn(scan.results)
	StopScanning()

	RecordPrices()
	BuildResultsFrame()
	ApplyView(true)

	resultsFrame:Show()
	E:Print(format(L["AUCTION_SCAN_DONE"], scan.name, collected, scan.page + 1))

	RestoreFirstPage()
end

local function CollectPage()
	local batch, total = GetNumAuctionItems("list")
	batch = batch or 0
	scan.total = total or 0
	scan.awaitingPage = false

	for i = 1, batch do
		local name, _, count, quality, _, level, minBid, _, buyoutPrice, bidAmount, _, owner = GetAuctionItemInfo("list", i)
		if name and count and count > 0 then
			local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
			local buyout = buyoutPrice or 0
			local timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("list", i)

			tinsert(scan.results, {
				name = name,
				count = count,
				quality = quality or 1,
				level = level,
				page = scan.page,
				--minBid rather than the current bid, for matching this auction again later:
				--a bid placed between the scan and the click changes bidAmount and leaves
				--minBid alone, so the stable field is the one to identify it by.
				minBid = minBid or 0,
				bid = bid,
				buyout = buyout,
				unitBid = floor((bid / count) + 0.5),
				unitBuyout = (buyout > 0) and floor((buyout / count) + 0.5) or 0,
				owner = owner,
				timeText = timeLeft and _G["AUCTION_TIME_LEFT"..timeLeft] or ""
			})
		end
	end

	local collected = getn(scan.results)
	local pages = 1
	if scan.total > 0 and batch > 0 then pages = ceil(scan.total / batch) end

	if scanButton then
		scanButton:SetText(format(L["Scanning %d/%d"], scan.page + 1, pages))
	end

	if batch == 0 or collected >= scan.total or (scan.page + 1) >= SCAN_MAX_PAGES then
		FinishScan()
	else
		scan.page = scan.page + 1
		scan.queryPending = true
		scan.nextQuery = GetTime() + SCAN_INTERVAL
	end
end

local function ScanOnUpdate()
	--A jump borrows the same pump: one gated-query state machine, so there is one place
	--where a query can be sent and one place that can get the gating wrong.
	if jump.active then
		if jump.queryPending then
			if GetTime() >= jump.nextQuery and CanSendAuctionQuery() then
				jump.queryPending = false
				jump.awaitingPage = true
				jump.deadline = GetTime() + SCAN_TIMEOUT
				QueryAuctionItems(scan.name, scan.minLevel, scan.maxLevel, nil, nil, nil, jump.entry.page, nil, nil)
			end
		elseif jump.awaitingPage and GetTime() > jump.deadline then
			jump.active = false
			jump.awaitingPage = false
			jump.entry = nil
			this:SetScript("OnUpdate", nil)
			E:Print(L["AUCTION_JUMP_TIMEOUT"])
		end
		return
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
			scan.deadline = GetTime() + SCAN_TIMEOUT
			QueryAuctionItems(scan.name, scan.minLevel, scan.maxLevel, nil, nil, nil, scan.page, nil, nil)
		end
	elseif scan.awaitingPage and GetTime() > scan.deadline then
		local collected = getn(scan.results)
		StopScanning()
		E:Print(format(L["AUCTION_SCAN_TIMEOUT"], collected))
		if collected > 0 then
			RecordPrices()
			BuildResultsFrame()
			ApplyView(true)
			resultsFrame:Show()
		end
		RestoreFirstPage()
	end
end

local function StartScan()
	if scan.active then
		local collected = getn(scan.results)
		StopScanning()
		E:Print(format(L["AUCTION_SCAN_CANCELLED"], collected))
		RestoreFirstPage()
		return
	end

	if not (_G.AuctionFrame and _G.AuctionFrame:IsShown()) then return end

	local name, minLevel, maxLevel = ScanFieldsFromUI()
	if name == "" then
		E:Print(L["AUCTION_SCAN_NEEDS_NAME"])
		return
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

	if scanButton then scanButton:SetText(L["Cancel"]) end
	scan.frame:SetScript("OnUpdate", scan.onUpdate)
end

local function BuildScanButton()
	if scanButton or not _G.AuctionFrameBrowse then return end

	local b = CreateFrame("Button", "ElvUI_AuctionScanButton", _G.AuctionFrameBrowse, "UIPanelButtonTemplate")
	E:Width(b, 74)
	E:Height(b, 22)
	b:SetText(L["Scan"])

	if _G.BrowseSearchButton then
		E:Point(b, "RIGHT", _G.BrowseSearchButton, "LEFT", -4, 0)
	else
		E:Point(b, "TOPRIGHT", _G.AuctionFrameBrowse, "TOPRIGHT", -90, -30)
	end

	b:SetScript("OnClick", function() StartScan() end)

	local skins = E:GetModule("Skins", true)
	if skins and skins.HandleButton then skins:HandleButton(b) end

	scanButton = b
	M.AuctionScanButton = b
end

local eventFrame
local installed = false

local function Install()
	--Blizzard_AuctionUI is a load-on-demand addon, so its frames exist only after it has
	--loaded. Nothing below is reachable before BrowseButton1 does.
	if installed or not _G.BrowseButton1 then return end
	installed = true

	if type(_G.AuctionFrameBrowse_Update) == "function" then
		--The function the browse list rebuilds itself with. Hooking it covers a page
		--arriving, a search, a sort and a scroll in one place, because the scroll frame
		--resolves this same global when it updates.
		hooksecurefunc("AuctionFrameBrowse_Update", UpdateBrowseRows)
		M.auctionHookPath = "AuctionFrameBrowse_Update"
	else
		--This client names it something else. The event covers a page arriving and the
		--scroll handler covers moving within the page already held; between them that is
		--everything the hook would have caught. Said out loud rather than left to look
		--like a display bug, because the fallback is the unexpected branch.
		eventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
		if _G.BrowseScrollFrame then
			HookScript(_G.BrowseScrollFrame, "OnVerticalScroll", UpdateBrowseRows)
		end
		M.auctionHookPath = "AUCTION_ITEM_LIST_UPDATE"
		E:Print(L["Auction house: AuctionFrameBrowse_Update is missing, using the event fallback for per-unit prices."])
	end

	BuildScanButton()
	UpdateBrowseRows()
end

function M:LoadAuctionHouse()
	--Parked. See the block at the top of this file; flip ENABLED to bring it all back.
	if not ENABLED then return end
	if eventFrame then return end

	eventFrame = CreateFrame("Frame", "ElvUI_AuctionBrowse", UIParent)
	eventFrame:RegisterEvent("ADDON_LOADED")
	eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
	eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
	--Registered unconditionally now, because the scan is driven by it whichever way the
	--row annotation ended up hooked. The annotation still redraws off the function hook
	--where that exists: our handler can run BEFORE Blizzard has refilled the rows, and
	--reading them at that moment prices the previous page's auctions.
	eventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
	eventFrame:SetScript("OnEvent", function()
		if event == "ADDON_LOADED" then
			if arg1 == "Blizzard_AuctionUI" then Install() end
		elseif event == "AUCTION_ITEM_LIST_UPDATE" then
			if scan.active and scan.awaitingPage then
				CollectPage()
			elseif jump.active and jump.awaitingPage then
				FinishJump()
				this:SetScript("OnUpdate", nil)
			elseif M.auctionHookPath == "AUCTION_ITEM_LIST_UPDATE" then
				UpdateBrowseRows()
			end
		elseif event == "AUCTION_HOUSE_CLOSED" then
			--Walking away from the auctioneer ends the scan. Queries would fail anyway and
			--the results already collected are still worth keeping, so the window stays.
			if scan.active then
				StopScanning()
				E:Print(format(L["AUCTION_SCAN_CANCELLED"], getn(scan.results)))
			end
			scan.restorePending = false
			jump.active = false
			jump.awaitingPage = false
			jump.entry = nil
			markedAuction = nil
		else
			Install()
		end
	end)

	scan.frame = eventFrame
	scan.onUpdate = ScanOnUpdate

	M.AuctionBrowseFrame = eventFrame
	--Exposed so the config toggle can clear the rows the moment it is switched off,
	--rather than at the next time the list happens to redraw.
	M.UpdateAuctionBrowse = UpdateBrowseRows
	M.StartAuctionScan = StartScan

	--Blizzard_AuctionUI may already be loaded by the time OctoUI initialises, in which
	--case ADDON_LOADED has been and gone.
	if IsAddOnLoaded("Blizzard_AuctionUI") then Install() end
end
