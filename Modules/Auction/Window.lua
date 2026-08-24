local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local ipairs, unpack, pcall, tostring = ipairs, unpack, pcall, tostring
local format = string.format
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

	--Remembered before it changes, because OnSelect must fire on a CHANGE of tab and
	--not on every call. The tab buttons re-select the current tab from their OnLeave
	--handler, so merely moving the mouse across the tab strip was re-running whatever
	--a tab does when it opens -- for the Auctions tab that is a full re-read of your
	--auctions, several times a second, which then blocked the cancel that was waiting
	--for a quiet moment to run in.
	local previousTab = window.currentTab
	window.currentTab = id

	--Built on first sight rather than at construction, so a tab nobody opens
	--never costs a frame. 1.12 never frees one, which makes that worth doing.
	local tab = window.tabs[id]
	if tab and not tab.built then
		if A.tabBuilders[id] then
			--Latched only once a builder has actually run. Latching on the way past a
			--MISSING builder is a bug I shipped: a tab whose file had not registered
			--yet got a "not built yet" label and `built = true`, so it never tried
			--again for the rest of the session even after the builder appeared. A
			--placeholder is a thing to draw, not a thing to remember.
			tab.built = true

			--[[
				A TAB THAT ERRORS MUST NOT TAKE THE AUCTION HOUSE WITH IT.

				Blizzard's AUCTION_HOUSE_SHOW is unregistered from AuctionFrame so their
				window never appears. That means an error anywhere along this path leaves
				the player with no auction house at all: the auctioneer chimes, the
				interaction happens, and nothing opens. One broken tab is one broken tab;
				it is not a reason to make the whole feature unreachable, and the error
				needs saying out loud rather than vanishing into an event handler.
			]]
			local ok, err = pcall(A.tabBuilders[id], tab)
			if not ok then
				A.tabErrors = A.tabErrors or {}
				A.tabErrors[id] = tostring(err)
				E:Print(format(L["AUCTION_TAB_FAILED"], id, tostring(err)))
			elseif tab.placeholder then
				tab.placeholder:Hide()
			end
		elseif not tab.placeholder then
			--Sell, Bids and Auctions have buttons and no builders yet. An empty panel
			--reads as a broken tab; saying so reads as an unfinished one.
			tab.placeholder = tab:CreateFontString(nil, "OVERLAY")
			E:FontTemplate(tab.placeholder, nil, 11, "NONE")
			E:Point(tab.placeholder, "CENTER", tab, "CENTER", 0, 0)
			tab.placeholder:SetText(L["This tab has not been built yet."])
			tab.placeholder:SetTextColor(0.5, 0.5, 0.5)
		end
	end

	--[[
		Re-lay out the columns every time a tab is shown.

		LayoutColumns divides the listing's CURRENT width between the columns, and a
		listing measured while its window was hidden reports no useful width at all --
		it falls back to a constant and then never recomputes, which leaves the columns
		occupying whatever fraction of the frame that constant happened to be.
	]]
	if tab and tab.listing and tab.listing.Refresh then pcall(tab.listing.Refresh, tab.listing) end

	if previousTab ~= id then
		--[[
			The status line belongs to the WINDOW, not to whichever tab wrote it, so
			whatever the last tab left down there is still sitting under the next one.
			The Auctions tab's "4 auction(s) of yours are up", read at the bottom of a
			Sell tab listing Solid Stone, says you have four Solid Stone auctions up.

			Cleared on the way in. Anything that still matters is either drawn on the
			tab itself or is about to be written again by whatever is running. The
			progress bar is deliberately left alone: a scan started on one tab is still
			running when you look at another, and that is worth seeing.
		]]
		A:SetStatus("")

		--Guarded for the same reason as the builder: opening a tab must never be able
		--to stop the window opening.
		if tab and tab.OnSelect then
			local ok, err = pcall(tab.OnSelect)
			if not ok then E:Print(format(L["AUCTION_TAB_FAILED"], id, tostring(err))) end
		end
	end
end

A.SelectTab = function(_, id) SelectTab(id) end

function A:BuildWindow()
	if self.window then return end

	local window = CreateFrame("Frame", "OctoUI_AuctionHouse", E.UIParent)
	E:Size(window, WIDTH, HEIGHT)
	E:SetTemplate(window, "Transparent")
	--[[
		Restore only a position stored in the CURRENT format.

		The first attempt computed an offset from the screen centre by hand, out of
		GetLeft, GetWidth and UIParent's width -- and GetWidth lies about these frames.
		The diagnostic in /octoui-ah status measures a page anchored to a 780-wide
		window at +8/-8 as 382. Arithmetic on that put the window somewhere off screen,
		where it sat "built" and invisible with nothing to report.

		Records without a `point` are from that format and are ignored, which quietly
		returns anyone holding a broken one to the middle of the screen.
	]]
	local saved = A:Settings().position
	if saved and saved.point and saved.relPoint then
		E:Point(window, saved.point, E.UIParent, saved.relPoint, saved.x or 0, saved.y or 0)
	else
		E:Point(window, "CENTER", E.UIParent, "CENTER", 0, 0)
	end
	window:SetFrameStrata("HIGH")
	window:SetToplevel(true)
	window:Hide()

	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", function() this:StartMoving() end)
	window:SetScript("OnDragStop", function()
		this:StopMovingOrSizing()

		--[[
			Ask the frame where it ended up. Do not work it out.

			StopMovingOrSizing leaves a real anchor behind, and GetPoint hands it back
			exactly as SetPoint would take it -- no widths, no screen centre, no
			arithmetic on measurements that cannot be trusted. The previous version
			computed an offset from GetLeft and GetWidth and put the window off screen.
		]]
		local point, _, relPoint, x, y = this:GetPoint()
		if point then
			local db = A:Settings()
			db.position = {point = point, relPoint = relPoint or point, x = x or 0, y = y or 0}
		end
	end)

	--Escape closes it. UISpecialFrames takes the frame's global NAME, not the frame.
	tinsert(UISpecialFrames, "OctoUI_AuctionHouse")

	--Closing the window walks away from the auctioneer, which is what the player
	--means by closing it. Without this the server still thinks the session is open
	--and the next interaction misbehaves.
	window:SetScript("OnHide", function()
		--Only when the player closed it. Hiding UIParent -- which the AFK screen does,
		--among other things -- hides this window too, and treating that as "walked away
		--from the auctioneer" ends the session behind their back.
		if not UIParent:IsShown() then return end
		if CloseAuctionHouse then CloseAuctionHouse() end
	end)

	window.title = window:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(window.title, nil, 14, "OUTLINE")
	E:Point(window.title, "TOPLEFT", window, "TOPLEFT", 10, -9)
	window.title:SetText(L["Auction House"])

	--[[
		The bottom strip: a status line, and a progress bar that replaces it.

		They share the same space on purpose. A scan of the whole auction house runs
		for minutes, and a line of 10pt grey text in the corner of a transparent window
		is not feedback -- it was reported as "Scan All does nothing visible", and that
		was a fair reading: the text was updating and could not be seen. A bar that
		fills is legible at a glance from across the screen, which is the point when the
		thing being reported on takes several minutes.

		Bar while something is running, text when nothing is. Never both, so neither has
		to be laid out around the other.
	]]
	window.status = window:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(window.status, nil, 11, "NONE")
	E:Point(window.status, "BOTTOMLEFT", window, "BOTTOMLEFT", 10, 8)
	window.status:SetTextColor(0.8, 0.8, 0.8)

	local holder = CreateFrame("Frame", nil, window)
	E:Height(holder, 18)
	E:Point(holder, "BOTTOMLEFT", window, "BOTTOMLEFT", 10, 4)
	E:Point(holder, "BOTTOMRIGHT", window, "BOTTOMRIGHT", -10, 4)
	E:SetTemplate(holder, "Transparent")
	holder:Hide()

	local bar = CreateFrame("StatusBar", nil, holder)
	E:Point(bar, "TOPLEFT", holder, "TOPLEFT", 2, -2)
	E:Point(bar, "BOTTOMRIGHT", holder, "BOTTOMRIGHT", -2, 2)
	bar:SetStatusBarTexture(E.media.normTex)
	bar:SetStatusBarColor(unpack(E.media.rgbvaluecolor))
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	--[[
		The label belongs to the BAR, not to the holder.

		A child frame draws above its parent's regions whatever draw layer those
		regions are on, so a font string on the holder sits UNDER the bar and its
		fill. That is invisible while a scan is young and the fill is short, and the
		text silently disappears behind it somewhere past halfway -- reported as
		"the tracking vanished and left a bar". Created on the bar at OVERLAY, it is
		above the fill texture, which draws at ARTWORK.
	]]
	holder.text = bar:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(holder.text, nil, 11, "OUTLINE")
	E:Point(holder.text, "CENTER", bar, "CENTER", 0, 0)

	holder.bar = bar
	window.progress = holder

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

--[[
	Show the bar at page `page` of `pages`.

	`pages` can legitimately be zero or nil: the total only arrives with the first
	page, so the very first call of a scan has nothing to divide by. That is the
	normal case rather than an error, and it shows an empty bar with the label
	instead of dividing by zero or refusing to appear until page two.
]]
function A:SetProgress(page, pages, label)
	local progress = self.window and self.window.progress
	if not progress then return end

	local fraction = 0
	if pages and pages > 0 and page then
		fraction = page / pages
		if fraction > 1 then fraction = 1 end
		if fraction < 0 then fraction = 0 end
	end

	progress.bar:SetValue(fraction)
	progress.text:SetText(label or "")

	--[[
		A RUN THAT IS STARTING INVALIDATES THE LAST RUN'S RESULT.

		The bar and the status line share this strip, so HideProgress does not reveal
		nothing -- it reveals whatever the previous operation left behind. Post an
		auction, pick the next item, let its price check run, and the instant the bar
		goes away "Posted 1 auction(s)." is sitting there again, attached for anyone
		reading it to the scan that has just finished rather than to a post several
		actions ago. The line was true when it was written and is a lie by the time it
		is read a second time.

		Cleared on the way IN rather than on the way out, so anything that finishes
		with something to say still writes it after HideProgress and is seen. Only on
		the transition, because SetProgress is called per page and clearing every time
		would be pointless work.
	]]
	if not progress:IsShown() then self:SetStatus("") end

	if self.window.status then self.window.status:Hide() end
	progress:Show()
end

function A:HideProgress()
	local progress = self.window and self.window.progress
	if progress then progress:Hide() end
	if self.window and self.window.status then self.window.status:Show() end
end
