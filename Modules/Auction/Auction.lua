local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:NewModule("Auction", "AceEvent-3.0");
E.Auction = A

--Cache global variables
--Lua functions
local pairs, unpack = pairs, unpack
local format = string.format
local tinsert, getn = table.insert, table.getn
local _G = _G
--WoW API / Variables
local IsAddOnLoaded = IsAddOnLoaded
local CreateFrame = CreateFrame

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

--A single reason string, or nil when we are clear to run.
function A:Blocked()
	if not self:Settings().enable then return L["switched off"] end

	local other = self:CompetingAddon()
	if other then return format(L["%s is loaded and owns the auction house"], other) end

	return nil
end

function A:Toggle()
	local why = self:Blocked()
	if why then
		E:Print(format(L["OctoUI auction house: %s."], why))
		return
	end

	if not self.window then self:BuildWindow() end
	if not self.window then return end

	if self.window:IsShown() then self.window:Hide() else self.window:Show() end
end

function A:Command(msg)
	if msg == "status" then
		local other = self:CompetingAddon()
		E:Print(format(L["OctoUI auction house: %s."],
			self:Blocked() or L["ready"]))
		if other then
			E:Print(format(L["Disable %s and reload to use this instead."], other))
		end
		return
	end

	self:Toggle()
end

function A:AUCTION_HOUSE_SHOW()
	--Tracked whether or not we are the one showing a window: the scan needs to
	--know the session is open, and the session belongs to the auctioneer rather
	--than to any frame.
	self.atAuctionHouse = true
	if self:Blocked() then return end

	--Blizzard's frame is the one thing that must not also be open: it queries on
	--its own and its pages would land in the middle of ours.
	if _G.AuctionFrame then _G.AuctionFrame:Hide() end

	if not self.window then self:BuildWindow() end
	if self.window then self.window:Show() end
end

function A:AUCTION_HOUSE_CLOSED()
	self.atAuctionHouse = false
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
