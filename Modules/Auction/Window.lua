local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local ipairs, unpack = ipairs, unpack
local getn, tinsert = table.getn, table.insert
--WoW API / Variables
local CreateFrame = CreateFrame

--[[
	The window and its tab strip.

	Deliberately a plain frame parented to E.UIParent rather than a UIPanel. The
	auction house is something you sit in front of for a while with your bags
	open, and a UIPanel would fight the bag frames for the same anchored slots
	every time one opened.

	Tabs are frames that are shown and hidden, built lazily: whichever tab you
	never open costs nothing. Each tab file registers itself by filling
	A.tabBuilders, so adding one is a file rather than an edit here.
]]

local WIDTH, HEIGHT = 780, 480
local TAB_HEIGHT = 22

--Filled by the Tabs/ files. Key is the tab id, value builds the tab's content
--into the frame it is handed and returns nothing.
A.tabBuilders = A.tabBuilders or {}

A.TAB_LABEL = {
	["search"] = L["Search"],
	["post"] = L["Sell"],
	["bids"] = L["Bids"],
	["auctions"] = L["Auctions"]
}

local function SelectTab(id)
	local window = A.window
	if not window then return end

	for _, tabID in ipairs(A.TABS) do
		local tab = window.tabs[tabID]
		local button = window.tabButtons[tabID]
		if not (tab and button) then
			--A tab whose file is absent leaves no button and no page; nothing here
			--may assume all four exist, because a partial install would otherwise
			--take the whole window down rather than one tab.
		elseif tabID == id then
			tab:Show()
			button:SetBackdropBorderColor(unpack(E.media.rgbvaluecolor))
			button.text:SetTextColor(unpack(E.media.rgbvaluecolor))
		else
			tab:Hide()
			E:SetTemplate(button, "Transparent")
			button.text:SetTextColor(0.8, 0.8, 0.8)
		end
	end

	window.currentTab = id

	--Built on first sight rather than at construction, so a tab nobody opens
	--never costs a frame. 1.12 never frees one, which makes that worth doing.
	local tab = window.tabs[id]
	if tab and not tab.built and A.tabBuilders[id] then
		tab.built = true
		A.tabBuilders[id](tab)
	end

	if tab and tab.OnSelect then tab.OnSelect() end
end

A.SelectTab = function(_, id) SelectTab(id) end

function A:BuildWindow()
	if self.window then return end

	local window = CreateFrame("Frame", "OctoUI_AuctionHouse", E.UIParent)
	E:Size(window, WIDTH, HEIGHT)
	E:SetTemplate(window, "Transparent")
	E:Point(window, "CENTER", E.UIParent, "CENTER", 0, 0)
	window:SetFrameStrata("HIGH")
	window:SetToplevel(true)
	window:Hide()

	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", function() this:StartMoving() end)
	window:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

	--Escape closes it. UISpecialFrames takes the frame's global NAME, not the frame.
	tinsert(UISpecialFrames, "OctoUI_AuctionHouse")

	--Closing the window walks away from the auctioneer, which is what the player
	--means by closing it. Without this the server still thinks the session is open
	--and the next interaction misbehaves.
	window:SetScript("OnHide", function()
		if CloseAuctionHouse then CloseAuctionHouse() end
	end)

	window.title = window:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(window.title, nil, 14, "OUTLINE")
	E:Point(window.title, "TOPLEFT", window, "TOPLEFT", 10, -9)
	window.title:SetText(L["Auction House"])

	window.status = window:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(window.status, nil, 10, "NONE")
	E:Point(window.status, "BOTTOMLEFT", window, "BOTTOMLEFT", 10, 8)
	window.status:SetTextColor(0.6, 0.6, 0.6)

	E:CreateCloseButton(window, 16, -6)

	window.tabs = {}
	window.tabButtons = {}

	local previous
	for _, tabID in ipairs(A.TABS) do
		local button = CreateFrame("Button", nil, window)
		E:Size(button, 88, TAB_HEIGHT)
		E:SetTemplate(button, "Transparent")
		if previous then
			E:Point(button, "LEFT", previous, "RIGHT", 3, 0)
		else
			E:Point(button, "TOPLEFT", window, "TOPLEFT", 10, -30)
		end

		button.text = button:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(button.text, nil, 11, "NONE")
		button.text:SetAllPoints()
		button.text:SetText(A.TAB_LABEL[tabID] or tabID)
		button.tabID = tabID

		button:SetScript("OnClick", function() SelectTab(this.tabID) end)
		button:SetScript("OnEnter", function()
			if window.currentTab ~= this.tabID then this:SetBackdropBorderColor(1, 1, 1) end
		end)
		button:SetScript("OnLeave", function() SelectTab(window.currentTab) end)

		local page = CreateFrame("Frame", nil, window)
		E:Point(page, "TOPLEFT", window, "TOPLEFT", 8, -56)
		E:Point(page, "BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, 24)
		page:Hide()

		window.tabButtons[tabID] = button
		window.tabs[tabID] = page
		previous = button
	end

	self.window = window
	SelectTab(A.TABS[1])
end

function A:SetStatus(text)
	if self.window and self.window.status then
		self.window.status:SetText(text or "")
	end
end
