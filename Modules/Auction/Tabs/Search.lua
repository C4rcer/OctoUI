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
local GetAuctionItemClasses = GetAuctionItemClasses
local GetAuctionItemSubClasses = GetAuctionItemSubClasses
local GetAuctionInvTypes = GetAuctionInvTypes
local getglobal = getglobal
local UnitLevel = UnitLevel

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

--One row fewer than before, because the category browse takes a second filter
--row and the page is a fixed 400 tall: header, gap and 18 rows is 344 of the 348
--that are left. Nineteen overflowed the page and drew the last row over the
--status line.
local ROWS = 18

local function QualityColor(entry)
	local r, g, b = GetItemQualityColor(entry.quality or 1)
	return r, g, b
end

--[[
	Required level, red when you cannot use it yet.

	The whole point of browsing a slot is finding what you can wear NOW, and a list
	that shows nothing but prices makes you hover every row to find out. Red is the
	one piece of information that turns a scan of the column into a decision.
]]
local function LevelColor(entry)
	local level = entry.level or 0
	local mine = UnitLevel and UnitLevel("player") or 0

	if level > 0 and mine > 0 and level > mine then return 1, 0.3, 0.3 end
	return 0.9, 0.9, 0.9
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
	{key = "name", label = L["Item"], width = 22, color = QualityColor},
	--[[
		REQUIRED level, which is the same number Min and Max filter on -- so the column
		and the filter agree, rather than the column showing an item level the boxes
		never looked at.

		Sortable like every other header, which is the point: narrowing to 10-20 still
		leaves the list ordered by price, and "what is the best thing I can wear at 14"
		wants the level as the sort key. Zero means no requirement, which is a real
		answer rather than missing data, so it renders as a dash instead of a 0.
	]]
	{key = "level", label = L["Lvl"], width = 5, justify = "RIGHT", color = LevelColor,
		format = function(v)
			if not v or v <= 0 then return "|cff808080-|r" end
			return v
		end},
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
	{key = "owner", label = L["Seller"], width = 11}
}

--Which column holds a given key. Used for the default sort so that inserting a
--column never silently re-points it at a neighbour.
local function ColumnIndex(key)
	for i = 1, getn(COLUMNS) do
		if COLUMNS[i].key == key then return i end
	end
	return 1
end

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

--[[
	THE CATEGORY BROWSE.

	Blizzard's browse pane is a two-level list down the left of the auction house:
	a class, its subclasses, and for equipment the slots inside one. Replacing all
	of that with a single name box removed a whole way of shopping rather than
	simplifying it -- "level 32 cloth" is not a name, so there is nothing to type,
	and no amount of searching finds it. These are the same three indices that list
	produces and they go into the same three QueryAuctionItems arguments.

	MENUS RATHER THAN A TREE, for one reason that is not taste: the window is 780
	wide and a category column costs 150 of them off the results, which is where the
	three money columns already have nothing to spare -- see the column weight note
	above, where a truncated price does not read as truncated, it reads as a
	different number. Three buttons on a second filter row cost eighteen pixels of
	height and nothing at all horizontally.

	READ ONCE AND CACHED ON THE MODULE. The class tables are static client data, so
	rebuilding them per click is pure waste, and they are read lazily because the
	tab is built the first time the window opens rather than at login.
]]
local function ClassList()
	if not A.itemClasses then
		A.itemClasses = GetAuctionItemClasses and {GetAuctionItemClasses()} or {}
	end
	return A.itemClasses
end

local function SubClassList(class)
	if not (class and GetAuctionItemSubClasses) then return nil end

	A.itemSubClasses = A.itemSubClasses or {}
	if not A.itemSubClasses[class] then
		A.itemSubClasses[class] = {GetAuctionItemSubClasses(class)}
	end
	return A.itemSubClasses[class]
end

--[[
	The equipment slots within one subclass -- Head, Shoulder, Chest and so on.

	GUARDED ON THE FUNCTION EXISTING, unlike the two above. GetAuctionItemClasses and
	GetAuctionItemSubClasses are already relied on by Modules/Bags/Sort.lua and are
	therefore known to be here; GetAuctionInvTypes has never been measured on this
	client. If it is absent the slot button simply never offers anything and the
	other two levels still work, which is a browse that is narrower than Blizzard's
	rather than a tab that fails to build.

	It answers with the NAMES of global strings ("INVTYPE_HEAD"), not with text.
]]
local function InvTypeList(class, subclass)
	if not (class and subclass and GetAuctionInvTypes) then return nil end

	A.itemInvTypes = A.itemInvTypes or {}
	local key = class..":"..subclass
	if not A.itemInvTypes[key] then
		A.itemInvTypes[key] = {GetAuctionInvTypes(class, subclass)}
	end
	return A.itemInvTypes[key]
end

local function InvTypeLabel(token)
	if not token then return nil end
	return getglobal(token) or token
end

--Quality reads as its own colour, which is the only labelling anybody actually
--uses when picking one. Zero is a real index (Poor), so callers must test against
--nil rather than truthiness.
local function QualityLabel(index)
	local text = getglobal("ITEM_QUALITY"..index.."_DESC")
	if not text then return nil end

	local r, g, b = GetItemQualityColor(index)
	if not r then return text end

	return format("|cff%02x%02x%02x%s|r", floor(r * 255), floor(g * 255), floor(b * 255), text)
end

--[[
	One menu entry, built by a FUNCTION CALL rather than inside the loop body.

	A closure created in a loop has been measured on this client reading the loop's
	own variable as nil when it later ran -- the column header handlers in
	Listing.lua carry the worked example and the symptom, which is an "attempt to
	index a nil value" from a handler that looks perfectly ordinary. A parameter is
	unambiguously fresh per call and cannot have that problem, so every entry below
	is made through here rather than written out where the loop can reach it.
]]
local function MenuEntry(label, apply, value)
	return {text = label, func = function() apply(value) end}
end

--[[
	A button that shows what it is currently filtering on.

	Grey placeholder for "not filtering", value colour for a live filter, so the
	state of the whole browse reads at a glance without opening anything. An
	unavailable level -- a subclass with no class chosen, or slots on a client with
	no GetAuctionInvTypes -- is darker still and swallows its own clicks, rather
	than opening a menu with one entry in it.
]]
local function FilterButton(page, width, placeholder)
	local button = CreateFrame("Button", nil, page)
	E:Size(button, width, 18)
	E:SetTemplate(button, "Transparent")

	button.text = button:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(button.text, nil, 11, "NONE")
	button.text:SetAllPoints()
	button.placeholder = placeholder
	button.available = true

	function button:SetValue(text)
		if text then
			self.text:SetText(text)
			self.text:SetTextColor(unpack(E.media.rgbvaluecolor))
		else
			self.text:SetText(self.placeholder)
			self.text:SetTextColor(self.available and 0.45 or 0.25,
				self.available and 0.45 or 0.25, self.available and 0.45 or 0.25)
		end
	end

	button:SetScript("OnEnter", function()
		if this.available then this:SetBackdropBorderColor(1, 1, 1) end
	end)
	button:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)
	button:SetValue(nil)

	return button
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

	----------------------------------------------------------------------------
	-- The second filter row: category, subcategory, slot, quality, usable.
	----------------------------------------------------------------------------

	--The browse, as the arguments QueryAuctionItems actually takes. Held on the tab
	--rather than read off the buttons at query time, so one walk asks one question:
	--changing a dropdown mid-scan must not let page 7 of a cloth search come back
	--leather.
	local filters = {}

	--One frame for all four menus. E:DropDown needs a named frame -- it puts the
	--name into UISpecialFrames so Escape closes it -- and five of them would be five
	--frames this client will never free.
	local menu = CreateFrame("Frame", "OctoUI_AuctionFilterMenu", E.UIParent)
	E:SetTemplate(menu, "Transparent")
	menu:Hide()

	local classButton = FilterButton(page, 108, L["Category"])
	E:Point(classButton, "TOPLEFT", search, "BOTTOMLEFT", 0, -8)

	local subButton = FilterButton(page, 118, L["Subcategory"])
	E:Point(subButton, "LEFT", classButton, "RIGHT", 4, 0)

	local slotButton = FilterButton(page, 108, L["Slot"])
	E:Point(slotButton, "LEFT", subButton, "RIGHT", 4, 0)

	local qualityButton = FilterButton(page, 90, L["Quality"])
	E:Point(qualityButton, "LEFT", slotButton, "RIGHT", 4, 0)

	local usableButton = FilterButton(page, 66, L["Usable"])
	E:Point(usableButton, "LEFT", qualityButton, "RIGHT", 4, 0)

	local clearButton = FilterButton(page, 56, L["Clear"])
	E:Point(clearButton, "LEFT", usableButton, "RIGHT", 4, 0)

	--Declared before everything that calls it. A local declared after the function
	--that uses it resolves to a nil global on this client, silently.
	local function RefreshFilters()
		local classes = ClassList()
		classButton:SetValue(filters.class and classes[filters.class] or nil)

		local subs = SubClassList(filters.class)
		subButton.available = (subs and getn(subs) > 0) and true or false
		subButton:SetValue(filters.subclass and subs and subs[filters.subclass] or nil)

		local slots = InvTypeList(filters.class, filters.subclass)
		slotButton.available = (slots and getn(slots) > 0) and true or false
		slotButton:SetValue(filters.invType and slots and InvTypeLabel(slots[filters.invType]) or nil)

		--Quality 0 is Poor, which is a real filter. Tested against nil rather than
		--truthiness everywhere it is read.
		qualityButton:SetValue((filters.quality ~= nil) and QualityLabel(filters.quality) or nil)
		usableButton:SetValue(filters.usable and L["Usable"] or nil)
	end
	RefreshFilters()

	local function OpenMenu(button, list)
		if not button.available then return end
		if getn(list) == 0 then return end

		--One frame for five buttons means a menu another button left open has to be
		--CLOSED rather than toggled: E:DropDown ends in ToggleFrame, so opening the
		--second menu while the first is up would hide it and leave the click looking
		--like it did nothing at all.
		if menu:IsShown() and menu.owner ~= button then menu:Hide() end
		menu.owner = button

		E:DropDown(list, menu, 0, 0)
	end

	--Choosing a level clears everything under it. A subclass index only means
	--anything inside its class, so carrying "Cloth" over from Armor into Weapon
	--would query subclass 2 of Weapon -- a different thing entirely, and one that
	--returns results, which is what makes it worth being careful about.
	local function SetClass(index)
		filters.class = index
		filters.subclass = nil
		filters.invType = nil
		RefreshFilters()
	end

	local function SetSubClass(index)
		filters.subclass = index
		filters.invType = nil
		RefreshFilters()
	end

	local function SetInvType(index)
		filters.invType = index
		RefreshFilters()
	end

	local function SetQuality(index)
		filters.quality = index
		RefreshFilters()
	end

	classButton:SetScript("OnClick", function()
		local classes = ClassList()
		local list = {MenuEntry(L["All categories"], SetClass, nil)}
		for i = 1, getn(classes) do
			tinsert(list, MenuEntry(classes[i], SetClass, i))
		end
		OpenMenu(this, list)
	end)

	subButton:SetScript("OnClick", function()
		local subs = SubClassList(filters.class)
		if not subs then return end

		local list = {MenuEntry(L["All subcategories"], SetSubClass, nil)}
		for i = 1, getn(subs) do
			tinsert(list, MenuEntry(subs[i], SetSubClass, i))
		end
		OpenMenu(this, list)
	end)

	slotButton:SetScript("OnClick", function()
		local slots = InvTypeList(filters.class, filters.subclass)
		if not slots then return end

		local list = {MenuEntry(L["All slots"], SetInvType, nil)}
		for i = 1, getn(slots) do
			tinsert(list, MenuEntry(InvTypeLabel(slots[i]), SetInvType, i))
		end
		OpenMenu(this, list)
	end)

	qualityButton:SetScript("OnClick", function()
		local list = {MenuEntry(L["Any quality"], SetQuality, nil)}
		--Poor through Legendary. Artifact exists as a quality and as nothing you can
		--put in an auction house.
		for i = 0, 5 do
			local label = QualityLabel(i)
			if label then tinsert(list, MenuEntry(label, SetQuality, i)) end
		end
		OpenMenu(this, list)
	end)

	usableButton:SetScript("OnClick", function()
		--1 or nil, not true or false: this reaches QueryAuctionItems as the checkbox
		--value Blizzard's own browse hands it.
		filters.usable = (not filters.usable) and 1 or nil
		RefreshFilters()
	end)
	usableButton:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Usable"])
		GameTooltip:AddLine(L["AUCTION_FILTER_USABLE_TIP"], 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	usableButton:SetScript("OnLeave", function()
		E:SetTemplate(this, "Transparent")
		GameTooltip:Hide()
	end)

	clearButton:SetScript("OnClick", function()
		filters.class, filters.subclass, filters.invType = nil, nil, nil
		filters.quality, filters.usable = nil, nil
		minLevel:SetText("")
		maxLevel:SetText("")
		RefreshFilters()
	end)
	clearButton:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Clear"])
		GameTooltip:AddLine(L["AUCTION_FILTER_CLEAR_TIP"], 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	clearButton:SetScript("OnLeave", function()
		E:SetTemplate(this, "Transparent")
		GameTooltip:Hide()
	end)

	--What the progress line calls this search. A category browse has nothing typed,
	--and "Searching for ..." with an empty space after it reads as a broken string
	--rather than as a search of everything in a category.
	local function Describe(name)
		if name and name ~= "" then return name end

		local classes = ClassList()
		local text = filters.class and classes[filters.class] or nil

		local subs = SubClassList(filters.class)
		if text and filters.subclass and subs and subs[filters.subclass] then
			text = text.." > "..subs[filters.subclass]
		end

		return text or L["everything"]
	end

	local listing = A:CreateListing(page, COLUMNS, ROWS, 740)
	E:Point(listing, "TOPLEFT", page, "TOPLEFT", 0, -52)
	E:Point(listing, "BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	--[[
		Cheapest per unit first is the question the tab exists to answer.

		BY KEY, NOT BY NUMBER. This was a literal 4, which meant "buyout per unit" only
		for as long as nothing was inserted to the left of it -- and adding the Lvl
		column silently moved it onto the bid column instead. A default sort landing one
		column off is invisible: the list is still sorted, still by a price, and still
		plausible. Looking the index up by key cannot drift.
	]]
	listing.sortColumn = ColumnIndex("unitBuyout")
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
			`exact` IS AN ITEM NAME, and the only caller that supplies one is A:SearchFor.

			A mouse button string is not an item, and mistaking one for an item is not a
			cosmetic error: the branch below treats a non-nil `exact` as "the player named
			exactly one thing" and clears the whole category browse before searching. So
			handing this "LeftButton" wipes Weapon > Daggers and then refuses the search
			for having no category selected, which is precisely what browsing did.

			The wrapper on the button below is the real fix. This is the guard that makes
			it impossible to reintroduce by attaching Go somewhere else.
		]]
		if exact == "LeftButton" or exact == "RightButton" or exact == "MiddleButton"
			or exact == "Button4" or exact == "Button5" then
			exact = nil
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

			--[[
				An exact search is for ONE named item, so it must not arrive narrowed by
				a category left over from browsing. Right-clicking a bag item while
				"Armor > Cloth" was selected would otherwise ask the server for that item
				*within cloth armour* and come back with nothing -- with the reason sitting
				one row above the empty list in plain sight, and no message saying so.
			]]
			filters.class, filters.subclass, filters.invType = nil, nil, nil
			filters.quality, filters.usable = nil, nil
			RefreshFilters()
		else
			listing.filter = nil
		end

		local name = search:GetText()
		if A:StartScan(name, tonumber(minLevel:GetText()), tonumber(maxLevel:GetText()),
			handlers, filters) then
			listing:SetData({})
			button.text:SetText(L["Cancel"])
			A:SetProgress(0, nil, format(L["Searching for %s..."], Describe(name)))
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

	--[[
		WRAPPED, never passed straight to SetScript.

		Script handlers on this client take no arguments and read `this` and `arg1` as
		globals -- but OnClick is the one that carries the mouse button, and Go's first
		parameter is an item name. Passing the function directly is exactly the mistake
		HANDOFF.md records as "passing a method straight to SetScript fails; wrap it",
		and Modules/Auras/Auras.lua wraps for the same reason.
	]]
	button:SetScript("OnClick", function() Go() end)
	scanAll:SetScript("OnClick", GoAll)
	search:SetScript("OnEnterPressed", function()
		this:ClearFocus()
		Go()
	end)

	listing.OnEnter = function(entry, row)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")

		--[[
			The real item tooltip: stats, the level requirement, the stack limit --
			everything the buying decision actually turns on, which is the entire point
			of hovering a row.

			This used to hand SetHyperlink the whole formatted link and got an empty
			tooltip back for its trouble, so a search result showed prices and no item
			at all. A:ItemTooltip owns that fix, owns the three places an item string
			can come from, and owns the fallback for a row whose item this client has
			genuinely never cached. See Listing.lua.
		]]
		A:ItemTooltip(GameTooltip, entry)

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
				function(bought, spent, stopped, missed)
					A:HideProgress()
					buyButton.text:SetText(L["Buy"])

					--Three outcomes, not two. A run that skipped past auctions somebody else
					--bought first delivered less than was agreed to, and saying only "bought
					--12" leaves the player to work out why it was not 28.
					local message
					if stopped and missed and missed > 0 then
						message = format(L["AUCTION_BULK_STOPPED_MISSED"], bought, pending.name,
							A:Money(spent), missed)
					elseif stopped then
						message = format(L["AUCTION_BULK_STOPPED"], bought, pending.name, A:Money(spent))
					elseif missed and missed > 0 then
						message = format(L["AUCTION_BULK_MISSED"], bought, pending.name, A:Money(spent), missed)
					else
						message = format(L["AUCTION_BULK_DONE"], bought, pending.name, A:Money(spent))
					end

					A:SetStatus(message)
					E:Print(message)

					--Anything short says where to read what happened, rather than leaving the
					--number to be reported back as a sentence with no evidence behind it.
					if stopped or (missed and missed > 0) then
						E:Print(L["AUCTION_BUYLOG_HINT"])
					end
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
		elseif reason == "capped" then
			--Ordinary now rather than pathological: a whole category routinely runs past
			--the 40-page search cap, so the count has to say it is the first 2000 of
			--something larger instead of reading as the complete answer.
			A:SetStatus(format(L["AUCTION_SEARCH_CAPPED"], collected))
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
