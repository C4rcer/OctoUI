local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local find, sub = string.find, string.sub
--WoW API / Variables
local CreateFrame = CreateFrame
local ClearCursor = ClearCursor
local CursorHasItem = CursorHasItem
local GetContainerItemLink = GetContainerItemLink
local IsShiftKeyDown = IsShiftKeyDown
local PickupContainerItem = PickupContainerItem

--[[
	Ported from ShaguTweaks-extras, mods/bag-item-click.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Right clicking a bag item while the trade window is open puts it in the
	trade; while the auction house browse tab is open it searches for it;
	while the sell tab is open it puts it in the auction slot. Shift keeps
	the default use/equip behavior. ElvUI's bag slots inherit
	ContainerFrameItemButtonTemplate, whose handlers resolve UseContainerItem
	and GameTooltip:SetBagItem globally, so the upstream hooks work as-is.
]]

function M:LoadBagItemClick()
	--helper functions
	local IsTrading = function()
		return TradeFrame and TradeFrame:IsShown()
	end

	local IsAuctionBrowsing = function()
		return AuctionFrame and AuctionFrame:IsShown() and AuctionFrameBrowse and AuctionFrameBrowse:IsShown()
	end

	local IsAuctionSelling = function()
		return AuctionFrame and AuctionFrame:IsShown() and AuctionFrameAuctions and AuctionFrameAuctions:IsShown()
	end

	--[[
		OctoUI's own auction window, when it is the one in front.

		Every check above tests Blizzard's AuctionFrame, and OctoUI's auction module
		hides that frame outright -- so all three go false at exactly the moment this
		feature is most wanted, and right-clicking a bag item at the auction house
		quietly does nothing. Asking our window which tab it is showing is the same
		question, put to the frame that is actually on screen.

		Resolved on each call rather than cached: the auction module is optional, is
		off by default, and stands down entirely when aux is loaded.
	]]
	local OctoAuctionTab = function()
		local A = E:GetModule("Auction", true)
		local window = A and A.window
		if not (window and window:IsShown()) then return nil end
		return window.currentTab
	end

	local ItemName = function(bag, slot)
		local link = GetContainerItemLink(bag, slot)
		if not link then return nil end

		local open, close = find(link, "%["), find(link, "%]")
		if not (open and close) then return nil end

		return sub(link, open + 1, close - 1)
	end

	--overwrite use/trade logic unless shift is pressed
	local origUseContainerItem = UseContainerItem
	_G.UseContainerItem = function(bag, slot)
		if not E.db.general.bagItemClick then
			return origUseContainerItem(bag, slot)
		end

		if IsTrading() and not IsShiftKeyDown() then
			--move item to trade window
			PickupContainerItem(bag, slot)
			local tradeSlot = TradeFrame_GetAvailableSlot()
			if tradeSlot then ClickTradeButton(tradeSlot) end
			if CursorHasItem() then
				ClearCursor()
			end
		elseif OctoAuctionTab() == "search" and not IsShiftKeyDown() then
			--Exact name, because the player has pointed at one specific item. The
			--server matches substrings, so the tab filters the results down.
			local A = E:GetModule("Auction", true)
			local name = ItemName(bag, slot)
			if not (name and A and A.SearchFor and A:SearchFor(name)) then
				origUseContainerItem(bag, slot)
			end
		elseif OctoAuctionTab() == "post" and not IsShiftKeyDown() then
			--Into OctoUI's sell slot, which also prices it against the scanned market.
			local A = E:GetModule("Auction", true)
			if not (A and A.SellFromBags and A:SellFromBags(bag, slot)) then
				origUseContainerItem(bag, slot)
			end
		elseif IsAuctionBrowsing() and not IsShiftKeyDown() then
			--search item in auction house
			local link = GetContainerItemLink(bag, slot)
			local name = link and sub(link, find(link, "%[") + 1, find(link, "%]") - 1) or ""
			BrowseName:SetText(name)
			AuctionFrameBrowse_Search()
		elseif IsAuctionSelling() and not IsShiftKeyDown() then
			--sell item at auction house
			PickupContainerItem(bag, slot)
			AuctionsItemButton:Click()
			if CursorHasItem() then
				ClearCursor()
			end
		else
			--default action
			origUseContainerItem(bag, slot)
		end
	end

	--detect bag button tooltips
	local showHelperNextTooltip = false
	local origSetBagItem = GameTooltip.SetBagItem
	GameTooltip.SetBagItem = function(self, container, slot)
		if E.db.general.bagItemClick then
			showHelperNextTooltip = IsTrading() or IsAuctionBrowsing() or IsAuctionSelling()
				or OctoAuctionTab() ~= nil
		end
		return origSetBagItem(self, container, slot)
	end

	--add helper text to tooltips
	local tooltip = CreateFrame("Frame", "ElvUI_BagItemClickHelp", GameTooltip)
	tooltip:SetScript("OnShow", function()
		if showHelperNextTooltip then
			GameTooltip:AddLine(L["Hold [Shift] to use item."], 0.50, 0.75, 1.00)
			GameTooltip:Show()
			showHelperNextTooltip = false
		end
	end)
end
