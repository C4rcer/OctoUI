local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local tonumber, unpack = tonumber, unpack
local format, lower, find = string.format, string.lower, string.find
local getn, tinsert = table.getn, table.insert
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

local ROWS = 20

local function QualityColor(entry)
	local r, g, b = GetItemQualityColor(entry.quality or 1)
	return r, g, b
end

local COLUMNS = {
	{key = "name", label = L["Item"], width = 30, color = QualityColor},
	{key = "count", label = L["Qty"], width = 6, justify = "RIGHT"},
	{key = "unitBid", label = L["Bid/ea"], width = 14, justify = "RIGHT",
		format = function(v) return A:Money(v) end},
	{key = "unitBuyout", label = L["Buyout/ea"], width = 14, justify = "RIGHT",
		format = function(v) return v > 0 and A:Money(v) or "|cff808080--|r" end},
	{key = "buyout", label = L["Total"], width = 14, justify = "RIGHT",
		format = function(v) return v > 0 and A:Money(v) or "|cff808080--|r" end},
	{key = "timeLeft", label = L["Time"], width = 8, justify = "RIGHT",
		format = function(v)
			--1 short, 2 medium, 3 long, 4 very long. The client gives a bucket,
			--not a number, so anything more precise would be invented.
			local text = {"30m", "2h", "8h", "24h"}
			return v and text[v] or ""
		end},
	{key = "owner", label = L["Seller"], width = 14}
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

	local listing = A:CreateListing(page, COLUMNS, ROWS, 740)
	E:Point(listing, "TOPLEFT", page, "TOPLEFT", 0, -26)
	E:Point(listing, "BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	--Cheapest per unit first is the question the tab exists to answer.
	listing.sortColumn = 4
	listing.sortDescending = false

	local function Go()
		if A:IsScanning() then
			A:CancelScan()
			return
		end

		local name = search:GetText()
		if A:StartScan(name, tonumber(minLevel:GetText()), tonumber(maxLevel:GetText())) then
			listing:SetData({})
			button.text:SetText(L["Cancel"])
			A:SetStatus(format(L["Searching for %s..."], name))
		end
	end

	button:SetScript("OnClick", Go)
	search:SetScript("OnEnterPressed", function()
		this:ClearFocus()
		Go()
	end)

	listing.OnEnter = function(entry, row)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:AddLine(entry.name)
		if entry.count > 1 then
			GameTooltip:AddLine(format(L["Stack of %d"], entry.count), 1, 1, 1)
		end
		GameTooltip:AddLine(format(L["Bid %s each"], A:Money(entry.unitBid)), 1, 1, 1)
		if entry.buyout > 0 then
			GameTooltip:AddLine(format(L["Buyout %s each"], A:Money(entry.unitBuyout)), 1, 1, 1)
		end
		GameTooltip:AddLine(L["Click to buy. The page it came from is re-queried first."],
			0.6, 0.6, 0.6, 1)
		GameTooltip:Show()
	end
	listing.OnLeave = function() GameTooltip:Hide() end

	listing.OnClick = function(entry)
		if entry.buyout <= 0 then
			E:Print(L["That auction has no buyout."])
			return
		end
		A:BuyEntry(entry)
	end

	page.listing = listing
	page.searchBox = search
	page.button = button

	--Set here rather than at module scope so the tab that owns the listing is the
	--one that hears about scans. A later tab scanning for its own reasons swaps
	--these for its own and puts them back.
	function A:OnScanProgress(pageNumber, collected, total)
		A:SetStatus(format(L["Page %d, %d of %d auctions"], pageNumber, collected, total or 0))
	end

	function A:OnScanComplete(results, reason, collected)
		button.text:SetText(L["Search"])
		listing:SetData(results)

		if reason == "timeout" then
			A:SetStatus(format(L["Timed out. %d auctions found."], collected))
		elseif reason == "cancelled" then
			A:SetStatus(format(L["Cancelled. %d auctions found."], collected))
		else
			A:SetStatus(format(L["%d auctions found."], collected))
		end
	end
end
