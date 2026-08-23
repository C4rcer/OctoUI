local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:NewModule("Auction", "AceEvent-3.0");
E.Auction = A

--Cache global variables
--Lua functions
local pairs, ipairs, unpack, tonumber = pairs, ipairs, unpack, tonumber
local pcall, tostring = pcall, tostring
local format, lower, find = string.format, string.lower, string.find
local tinsert, getn = table.insert, table.getn
local _G = _G
--WoW API / Variables
local IsAddOnLoaded = IsAddOnLoaded
local CreateFrame = CreateFrame
local CanSendAuctionQuery = CanSendAuctionQuery
local GetTime = GetTime
local HideUIPanel = HideUIPanel
local ShowUIPanel = ShowUIPanel

--[[
	OctoUI's auction house.

	WRITTEN FROM SCRATCH, and it has to be. aux-addon carries no licence file at
	all, which makes it all rights reserved -- the same position ShaguDPS is in,
	and Modules\Misc\DamageMeter.lua already records how this project handles
	that. Features and workflows are not copyrightable and the auction API's
	function names and return values are facts about the client, readable from
	any addon that consumes them. aux's CODE is not, and none of it is here.

	IT CANNOT SHARE THE AUCTION HOUSE. Only one addon can drive Blizzard's
	auction frame and its query throttle: two scanners calling QueryAuctionItems
	against one CanSendAuctionQuery gate interleave their pages and both end up
	with results that are silently wrong. So this stands down entirely whenever
	aux is loaded, and says so once rather than fighting it.

	The scan engine is NOT new. Modules\Misc\AuctionHouse.lua already walks every
	page of a search, prices per unit and banks the results in
	E.global.auctionPrices -- OctoUI's own code, parked in August because it was
	annotating Blizzard's browse rows and that was the wrong shape. Its own block
	comment says the row wants re-laying out with a real column. This window IS
	that re-lay, approached from the other side, and the engine moves here rather
	than being written twice.
]]

--Addons that own the auction house. If any is loaded we are a guest, not the host.
local COMPETING = {
	["aux-addon"] = "aux",
	["Auctioneer"] = "Auctioneer",
	["AuctionLite"] = "AuctionLite"
}

A.TABS = {"search", "post", "bids", "auctions"}

function A:CompetingAddon()
	for folder, label in pairs(COMPETING) do
		if IsAddOnLoaded(folder) then return label end
	end
end

function A:Settings()
	local db = E.db.general
	if not db.auction then db.auction = {} end
	--Off unless asked for, because something else is very likely already doing
	--this job and turning both on is worse than neither.
	if db.auction.enable == nil then db.auction.enable = false end
	return db.auction
end

--[[
	Is there an auction session open?

	THE EVENT IS NOT ENOUGH, and the case where it fails is not exotic. After a
	/reload at an auctioneer, AUCTION_HOUSE_SHOW has already fired and will not fire
	again, so atAuctionHouse reads false while the player is standing in front of the
	auctioneer with the window open. That made Scan All refuse with "you are not at an
	auctioneer" to somebody who plainly was.

	CanSendAuctionQuery is the fallback because it answers about the SESSION rather
	than about a frame: with no auctioneer there is nothing to query and it says so. It
	also answers false while genuinely at an auction house when a query is already in
	flight, which is why it is the fallback and not the primary -- a false negative
	there costs one retry, and the flag covers every case where the event did fire.

	Latching on success is deliberate. Once the session is known to exist, the rest of
	it should behave exactly as though the event had arrived, and AUCTION_HOUSE_CLOSED
	clears it again on the way out.
]]
function A:AtAuctionHouse()
	if self.atAuctionHouse then return true end

	if CanSendAuctionQuery and CanSendAuctionQuery() then
		self.atAuctionHouse = true
		return true
	end

	return false
end

--A single reason string, or nil when we are clear to run.
function A:Blocked()
	if not self:Settings().enable then return L["switched off"] end

	local other = self:CompetingAddon()
	if other then return format(L["%s is loaded and owns the auction house"], other) end

	return nil
end

--Switching on and off from chat, because the window has to be reachable from
--somewhere that does not already require it to be open. The config toggle in
--General is the same setting; neither needs a reload, since A:Blocked is
--re-evaluated on every event rather than cached at load.
function A:SetEnabled(enable)
	self:Settings().enable = enable and true or false

	if not enable then
		if self.window then self.window:Hide() end
		E:Print(L["OctoUI auction house switched off. Blizzard's own window comes back next time you visit an auctioneer."])
		return
	end

	self.saidWhyBlocked = nil
	E:Print(L["AUCTION_ENABLED"])

	--Already standing at the auctioneer when they switched it on, which is by far
	--the likeliest moment: open it now rather than making them walk away and back.
	--Through the event handler rather than Toggle, because Blizzard's frame is
	--sitting there open and only that path knows to dismiss it.
	if self:AtAuctionHouse() and not self:Blocked() then self:AUCTION_HOUSE_SHOW() end
end

function A:Toggle()
	local why = self:Blocked()
	if why then
		E:Print(format(L["OctoUI auction house: %s."], why))

		--A bare "switched off" leaves nowhere to go. The stand-down cases below it
		--are self-explanatory; this one is the addon refusing for a reason only it
		--knows about, so it has to say what to do next.
		if not self:Settings().enable then
			E:Print(L["AUCTION_HOW_TO_ENABLE"])
		end
		return
	end

	if not self.window then self:BuildWindow() end
	if not self.window then return end

	if self.window:IsShown() then self.window:Hide() else self.window:Show() end
end

--Only the verb is lowercased. The rest is an item name, and lowercasing it
--before it reaches the price report would print the player's search back at them
--in the wrong case even where the match itself does not care.
function A:Command(msg)
	local _, _, verb, rest = find(msg or "", "^(%S+)%s*(.*)$")
	verb = verb and lower(verb) or ""

	if verb == "on" or verb == "enable" then
		self:SetEnabled(true)
		return
	end

	if verb == "off" or verb == "disable" then
		self:SetEnabled(false)
		return
	end

	--A window that ends up somewhere unreachable cannot be dragged back, so there has
	--to be a way to recover it that does not involve editing saved variables.
	if verb == "reset" then
		self:Settings().position = nil
		if self.window then
			self.window:ClearAllPoints()
			E:Point(self.window, "CENTER", E.UIParent, "CENTER", 0, 0)
		end
		E:Print(L["AUCTION_POSITION_RESET"])
		return
	end

	--Measured pacing, so the scan interval can be set from evidence rather than from
	--a guess about what a server considers polite.
	if verb == "rate" then
		self:ScanRateReport()
		return
	end

	if verb == "status" then
		local other = self:CompetingAddon()
		E:Print(format(L["OctoUI auction house: %s."],
			self:Blocked() or L["ready"]))
		if other then
			E:Print(format(L["Disable %s and reload to use this instead."], other))
		elseif not self:Settings().enable then
			E:Print(L["AUCTION_HOW_TO_ENABLE"])
		end

		--[[
			Which tab files actually loaded.

			This exists because a tab drew "not built yet" when its builder was right
			there in a file that should have loaded, and there was no way to tell from
			inside the game whether the file had failed to load, the builder had failed
			to register, or the window was simply sitting on a different tab. Three
			possibilities, identical symptom, and no way to separate them without
			asking. One line of output settles it.

			A .lua file that fails to parse on this client does not load and says
			nothing, so "is the builder registered" is genuinely the question, not a
			roundabout way of asking something else.
		]]
		local builders = ""
		for _, tabID in ipairs(self.TABS) do
			builders = builders..(builders ~= "" and ", " or "")..tabID.."="
				..((self.tabBuilders and self.tabBuilders[tabID]) and L["yes"] or L["no"])
		end
		E:Print(format(L["AUCTION_STATUS_TABS"], builders))

		if self.window then
			E:Print(format(L["AUCTION_STATUS_WINDOW"], self.window.currentTab or "?"))

			--Column layout is arithmetic on a measured width, and a wrong measurement
			--looks exactly like wrong column weights from the outside.
			local tab = self.window.tabs and self.window.tabs[self.window.currentTab]
			local listing = tab and tab.listing
			if listing then
				E:Print(format(L["AUCTION_STATUS_WIDTH"],
					self.window:GetWidth() or 0, tab:GetWidth() or 0, listing:GetWidth() or 0))
			end
		else
			E:Print(L["Auction window: not built yet."])
		end

		--Prices.lua is a separate file, so "did the whole module load" and "did the
		--price store load" are different questions with the same symptom.
		E:Print(format(L["AUCTION_STATUS_PRICES"],
			self.RecordRow and L["yes"] or L["no"],
			(E.global and E.global.auctionPrices) and L["yes"] or L["no"]))
		return
	end

	--Starting a full scan from chat, so it does not need the window open and can be
	--fired the moment you reach the auctioneer.
	if verb == "scan" then
		if not self:AtAuctionHouse() then
			E:Print(L["Auction house: you are not at an auctioneer."])
			return
		end

		if self:IsScanning() then
			self:CancelScan()
			return
		end

		--"restart" forces page 0. Without it a scan that stopped at the page cap
		--carries on from where it left off, which is what somebody pressing it a
		--second time almost always means.
		self:StartFullScan(lower(rest or "") == "restart")
		return
	end

	--The price database is readable whether or not the window is: it is filled by
	--this module but it is not owned by it, and somebody running aux still has
	--whatever they collected before they installed it.
	if verb == "prices" then
		self:PriceReport(rest)
		return
	end

	if verb == "purge" then
		local days = tonumber(rest)
		--A bare "purge" does nothing. This deletes readings that cannot be got
		--back without walking to an auctioneer and scanning again, so it asks for
		--the number rather than assuming one.
		if not days or days <= 0 then
			E:Print(L["AUCTION_PURGE_USAGE"])
			return
		end

		E:Print(format(L["Auction prices: %d reading(s) older than %d day(s) removed."],
			self:PurgePrices(days), days))
		return
	end

	self:Toggle()
end

--[[
	Getting rid of Blizzard's auction frame, which is harder than hiding it.

	IT DOES NOT EXIST YET WHEN THE EVENT ARRIVES. Blizzard_AuctionUI is load on
	demand: on the first visit of a session AuctionFrame is nil while
	AUCTION_HOUSE_SHOW is being handled, so a single Hide() at that moment hides
	nothing at all, and the frame appears a moment later with ours behind it. That
	is not a theory about ordering -- it is what "load on demand" means, and it is
	why one hide on the event is not enough. So the hide repeats for a short budget
	afterwards, which covers the frame arriving late whatever the cause.

	HideUIPanel, NOT :Hide(). AuctionFrame is registered in UIPanelWindows, and
	hiding a panel behind the panel system's back leaves it holding a slot the
	system still believes is occupied -- the next panel to open lands in the wrong
	place, or does not open at all.

	Bounded rather than permanent. A live OnUpdate for as long as the auction house
	is open, to guard against a frame nobody is going to show, is a cost paid every
	frame for a case that ends within one.
]]
local DISMISS_BUDGET = 1.0

local dismiss

--[[
	HIDING BLIZZARD'S AUCTION FRAME CLOSES THE AUCTION HOUSE. This is the single
	fact this whole module lives or dies on.

	AuctionFrame carries an OnHide script that calls CloseAuctionHouse(). So the
	obvious implementation -- show our window, hide theirs -- ends the session with
	the server the instant our window appears. Nothing errors. The window sits there
	looking correct and every query from then on goes into a closed session and is
	never answered, which surfaces as scans timing out with zero results and as
	"you are not at an auctioneer" while standing at an auctioneer. Three different
	symptoms, one cause, and none of them points at the frame that was hidden.

	Clearing that script is what makes hiding it safe, and unregistering
	AUCTION_HOUSE_SHOW from it is what stops it coming back. Both are idempotent and
	both must happen BEFORE anything hides the frame.

	Blizzard_AuctionUI is load on demand, so the frame does not exist until the first
	visit -- hence ADDON_LOADED as well as a check at Initialize for the case where
	something else has already pulled it in.
]]
local function NeutraliseBlizzardFrame()
	local frame = _G.AuctionFrame
	if not frame or frame.octoNeutralised then return false end

	frame.octoNeutralised = true
	frame:SetScript("OnHide", nil)
	frame:UnregisterEvent("AUCTION_HOUSE_SHOW")

	--[[
		Blizzard's Auctions tab still listens for AUCTION_OWNED_LIST_UPDATE, which the
		server sends every time an auction is posted -- including ours. Its handler
		calls AuctionFrameAuctions_Update, which does arithmetic on
		AuctionFrameAuctions.page, and that field is only ever set when the frame is
		SHOWN. We never show it, so posting an auction throws

		    attempt to perform arithmetic on field 'page' (a nil value)

		out of Blizzard_AuctionUI.lua, from code we never called. The auctions post
		perfectly well; the error is purely their tab trying to redraw itself blind.

		Wrapped rather than unregistered, so the frame still behaves normally if
		anything ever does show it.
	]]
	if _G.AuctionFrameAuctions_OnEvent and not A.wrappedAuctionsEvent then
		A.wrappedAuctionsEvent = true

		local original = _G.AuctionFrameAuctions_OnEvent
		--Vararg form: 5.0 only fills the implicit `arg` table for a function declared
		--with (...), and the handler is called with the event in some code paths.
		_G.AuctionFrameAuctions_OnEvent = function(...)
			local tab = _G.AuctionFrameAuctions
			if tab and tab:IsVisible() then return original(unpack(arg)) end
		end
	end

	return true
end

A.NeutraliseBlizzardFrame = function() return NeutraliseBlizzardFrame() end

local function DismissBlizzardFrame()
	--Never hide it before its OnHide has been cleared, or hiding it is the thing
	--that closes the auction house.
	NeutraliseBlizzardFrame()

	local frame = _G.AuctionFrame
	if frame and frame:IsShown() then
		if HideUIPanel then HideUIPanel(frame) else frame:Hide() end
	end
end

local function DismissOnUpdate()
	DismissBlizzardFrame()
	if GetTime() >= this.deadline then this:SetScript("OnUpdate", nil) end
end

local function StopDismissing()
	if dismiss then dismiss:SetScript("OnUpdate", nil) end
end

--Fires for every addon that loads; the only one that matters is the auction UI,
--and it has to be neutralised before anything gets a chance to hide it.
function A:ADDON_LOADED(_, addon)
	if addon == "Blizzard_AuctionUI" then
		--[[
			ONLY WHEN WE ARE ACTUALLY GOING TO REPLACE IT.

			Neutralising unconditionally is how the auction house stopped opening at
			all: the module can decline to run -- switched off, or standing down for
			aux -- but Blizzard's window had already been permanently disabled by then,
			so nothing opened and nothing said why. The auctioneer chimes, the NPC
			turns, and the player is left with no auction house of any kind, which is
			worse than either outcome on its own.
		]]
		if not self:Blocked() then NeutraliseBlizzardFrame() end
		self:UnregisterEvent("ADDON_LOADED")
	end
end

function A:AUCTION_HOUSE_SHOW()
	--Tracked whether or not we are the one showing a window: the scan needs to
	--know the session is open, and the session belongs to the auctioneer rather
	--than to any frame.
	self.atAuctionHouse = true

	local why = self:Blocked()
	if why then
		--Blizzard's frame may already have been neutralised earlier in the session --
		--the option can be switched off after the fact. Show it explicitly so there is
		--always an auction house, and say once why ours is not the one appearing.
		if _G.AuctionFrame and ShowUIPanel then ShowUIPanel(_G.AuctionFrame) end

		if not self.saidWhyBlocked then
			self.saidWhyBlocked = true
			E:Print(format(L["OctoUI auction house: %s."], why))
			if not self:Settings().enable then E:Print(L["AUCTION_HOW_TO_ENABLE"]) end
		end
		return
	end

	--Deferred to here rather than done at load, so switching the module off leaves
	--Blizzard's window working.
	NeutraliseBlizzardFrame()

	--Blizzard's frame is the one thing that must not also be open: it queries on
	--its own and its pages would land in the middle of ours.
	DismissBlizzardFrame()

	if not dismiss then dismiss = CreateFrame("Frame") end
	dismiss.deadline = GetTime() + DISMISS_BUDGET
	dismiss:SetScript("OnUpdate", DismissOnUpdate)

	if not self.window then
		--Guarded, because the alternative to our window is NO window: Blizzard's
		--AUCTION_HOUSE_SHOW has been unregistered by this point, so anything that
		--throws in here leaves the auctioneer chiming and nothing opening.
		local ok, err = pcall(self.BuildWindow, self)
		if not ok then E:Print(format(L["AUCTION_WINDOW_FAILED"], tostring(err))) end
	end

	if not self.window then
		--Nothing of ours to show. Hand the player back Blizzard's auction house rather
		--than leaving them standing at an auctioneer that does nothing at all.
		if _G.AuctionFrame and ShowUIPanel then
			E:Print(L["AUCTION_FELL_BACK"])
			ShowUIPanel(_G.AuctionFrame)
		end
		return
	end

	if self.window then
		self.window:Show()

		--Re-select the current tab on every open, which re-attempts any builder that
		--was not registered when the window was constructed. Cheap -- SelectTab only
		--builds a tab once -- and it turns "that tab is dead for the session" into
		--"that tab works the next time you walk up to an auctioneer".
		if self.window.currentTab then self:SelectTab(self.window.currentTab) end
	end
end

function A:AUCTION_HOUSE_CLOSED()
	self.atAuctionHouse = false
	StopDismissing()
	if self.CancelScan then self:CancelScan() end
	if self.window then self.window:Hide() end
end

--One page arrives at a time and a buy is never in flight with a scan, so the
--buy gets first refusal: it is the one with money riding on it.
function A:AUCTION_ITEM_LIST_UPDATE()
	if self.BuyPageArrived and self:BuyPageArrived() then return end
	if self.AuctionListUpdated then self:AuctionListUpdated() end
end

function A:Initialize()
	self.Initialized = true

	--Registered regardless of the block, because the block is re-evaluated on every
	--event: switching the option on should not need a reload, and an addon being
	--loaded is not something that changes mid-session anyway.
	self:RegisterEvent("AUCTION_HOUSE_SHOW")
	self:RegisterEvent("AUCTION_HOUSE_CLOSED")
	self:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

	--Blizzard_AuctionUI is load on demand, so AuctionFrame usually does not exist
	--yet. Catch it the moment it does, and also handle the case where something
	--else pulled it in before this module initialised.
	self:RegisterEvent("ADDON_LOADED")
	if not self:Blocked() then NeutraliseBlizzardFrame() end

	--Said once at login rather than every time the auction house opens. Somebody
	--running aux deliberately does not need telling four times a session.
	local other = self:CompetingAddon()
	if other and self:Settings().enable then
		E:Print(format(L["OctoUI auction house is off: %s is loaded and owns the auction house."], other))
	end
end

local function InitializeCallback()
	A:Initialize()
end

E:RegisterModule(A:GetName(), InitializeCallback)
