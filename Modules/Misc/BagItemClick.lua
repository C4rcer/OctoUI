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
