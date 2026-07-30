local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local find, gsub = string.find, string.gsub
local pairs = pairs
--WoW API / Variables
local CreateFrame = CreateFrame
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local GetItemInfo = GetItemInfo
local HasAction = HasAction
local IsConsumableAction = IsConsumableAction

--[[
	Ported from ShaguTweaks-extras, mods/actionbar-reagents.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Shows how many reagents are left on action buttons whose spell consumes
	them. Upstream leaned on ShaguTweaks' general purpose libtipscan and a
	GetItemCount helper; all that is needed here is "what does the Reagents
	line of this action's tooltip say" and a bag count by item name, so both
	are inlined. ElvUI's bars reuse the Blizzard action buttons, so the
	button names match upstream.
]]

--hidden tooltip for reading the Reagents: line off an action slot
local scanner
local function ScanActionReagents(slot, capture)
	if not scanner then
		scanner = CreateFrame("GameTooltip", "ElvUI_ReagentScanTooltip", nil, "GameTooltipTemplate")
		scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
	end
	scanner:ClearLines()
	scanner:SetAction(slot)
	for i = 1, scanner:NumLines() do
		local left = _G["ElvUI_ReagentScanTooltipTextLeft"..i]
		local text = left and left:GetText()
		if text then
			local found, _, reagents = find(text, capture)
			if found then return reagents end
		end
	end
end

--bag count by item name (from ShaguTweaks helpers.lua GetItemCount)
local function GetItemCountByName(itemName)
	local count = 0
	for bag = 4, 0, -1 do
		for slot = 1, GetContainerNumSlots(bag) do
			local _, itemCount = GetContainerItemInfo(bag, slot)
			if itemCount then
				local itemLink = GetContainerItemLink(bag, slot)
				local _, _, itemID = find(itemLink or "", "item:(%d+)")
				local queryName = itemID and GetItemInfo(itemID)
				if queryName and queryName ~= "" and queryName == itemName then
					count = count + itemCount
				end
			end
		end
	end

	return count
end

function M:LoadReagentCounter()
	local reagent_slots = {}
	local reagent_counts = {}
	local reagent_capture = SPELL_REAGENTS.."(.+)"
	local prefixes = { "Action", "BonusAction", "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarLeft", "MultiBarRight" }

	local reagentcounter = CreateFrame("Frame", "ElvUI_ReagentCounter", UIParent)
	reagentcounter:RegisterEvent("PLAYER_ENTERING_WORLD")
	reagentcounter:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	reagentcounter:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
	reagentcounter:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
	reagentcounter:RegisterEvent("BAG_UPDATE")

	reagentcounter:SetScript("OnEvent", function()
		this.event = true
	end)

	local function ScanSlot(slot)
		--update slots that previously had a reagent
		if reagent_slots[slot] and not HasAction(slot) then
			reagent_slots[slot] = nil
		end

		--search for reagent requirements
		if HasAction(slot) then
			local reagents = ScanActionReagents(slot, reagent_capture)
			--remove reagent counts if existing, "Ankh (2)" -> "Ankh"
			reagents = reagents and gsub(reagents, " %((.+)%)", "")

			--update on reagent requirement changes
			if reagents and reagent_slots[slot] ~= reagents then
				reagent_counts[reagents] = reagent_counts[reagents] or 0
				reagent_slots[slot] = reagents
			end
		end
	end

	local function UpdateButtons(enabled)
		for _, prefix in pairs(prefixes) do
			for i = 1, NUM_ACTIONBAR_BUTTONS do
				local button = _G[prefix.."Button"..i]
				local text = button and _G[button:GetName().."Count"]
				local slot = button and ActionButton_GetPagedID(button)

				if slot and text then
					if enabled and reagent_slots[slot] then
						text:SetText(reagent_counts[reagent_slots[slot]])
					elseif not IsConsumableAction(slot) then
						text:SetText()
					end
				end
			end
		end
	end

	reagentcounter:SetScript("OnUpdate", function()
		if not this.event then return end

		if not E.db.general.reagentCounter then
			--clear anything we were showing, then go dormant until re-enabled
			if next(reagent_slots) then
				UpdateButtons(false)
				for k in pairs(reagent_slots) do reagent_slots[k] = nil end
				for k in pairs(reagent_counts) do reagent_counts[k] = nil end
			end
			this.event = nil
			return
		end

		--update all slots after each event
		for slot = 1, 120 do
			ScanSlot(slot)
		end

		--scan for all reagent item counts
		for item in pairs(reagent_counts) do
			reagent_counts[item] = GetItemCountByName(item)
		end

		UpdateButtons(true)

		this.event = nil
	end)

	M.ReagentCounterFrame = reagentcounter
end
