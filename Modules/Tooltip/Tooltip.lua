local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local TT = E:NewModule("Tooltip", "AceHook-3.0", "AceEvent-3.0");
local LIP = LibStub:GetLibrary("ItemPrice-1.1");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack
local getn, twipe, tinsert, tconcat = table.getn, table.wipe, table.insert, table.concat
local floor = math.floor
local find, format, match = string.find, string.format, string.match
local time = time
--WoW API / Variables
local GetActionCount = GetActionCount
local GetAuctionItemInfo = GetAuctionItemInfo
local GetAuctionItemLink = GetAuctionItemLink
local GetAuctionSellItemInfo = GetAuctionSellItemInfo
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetCraftItemLink = GetCraftItemLink
local GetCraftReagentInfo = GetCraftReagentInfo
local GetCraftReagentItemLink = GetCraftReagentItemLink
local GetCraftSelectionIndex = GetCraftSelectionIndex
local GetGuildInfo = GetGuildInfo
local GetInboxItem = GetInboxItem
local GetInventoryItemCount = GetInventoryItemCount
local GetInventoryItemLink = GetInventoryItemLink
local GetItemCount = GetItemCount
local GetItemInfo = GetItemInfo
local GetItemInfoByName = GetItemInfoByName
local GetLootRollItemInfo = GetLootRollItemInfo
local GetLootRollItemLink = GetLootRollItemLink
local GetLootSlotInfo = GetLootSlotInfo
local GetLootSlotLink = GetLootSlotLink
local GetMerchantItemInfo = GetMerchantItemInfo
local GetMerchantItemLink = GetMerchantItemLink
local GetNumPartyMembers = GetNumPartyMembers
local GetNumRaidMembers = GetNumRaidMembers
local GetQuestItemInfo = GetQuestItemInfo
local GetQuestItemLink = GetQuestItemLink
local GetQuestLogItemLink = GetQuestLogItemLink
local GetQuestLogRewardInfo = GetQuestLogRewardInfo
local GetSendMailItem = GetSendMailItem
local GetTradePlayerItemInfo = GetTradePlayerItemInfo
local GetTradePlayerItemLink = GetTradePlayerItemLink
local GetTradeSkillItemLink = GetTradeSkillItemLink
local GetTradeSkillReagentInfo = GetTradeSkillReagentInfo
local GetTradeSkillReagentItemLink = GetTradeSkillReagentItemLink
local GetTradeTargetItemInfo = GetTradeTargetItemInfo
local GetTradeTargetItemLink = GetTradeTargetItemLink
local IsConsumableAction = IsConsumableAction
local IsShiftKeyDown = IsShiftKeyDown
local UnitClass = UnitClass
local UnitClassification = UnitClassification
local UnitCreatureType = UnitCreatureType
local UnitExists = UnitExists
local UnitIsPVP = UnitIsPVP
local UnitIsPlayer = UnitIsPlayer
local UnitIsTapped = UnitIsTapped
local UnitIsTappedByPlayer = UnitIsTappedByPlayer
local UnitIsUnit = UnitIsUnit
local UnitLevel = UnitLevel
local UnitName = UnitName
local UnitPVPName = UnitPVPName
local UnitRace = UnitRace
local UnitReaction = UnitReaction

local targetList = {}
local TAPPED_COLOR = {r = 0.6, g = 0.6, b = 0.6}

local classification = {
	worldboss = format("|cffAF5050 %s|r", BOSS),
	rareelite = format("|cffAF5050+ %s|r", ITEM_QUALITY3_DESC),
	elite = "|cffAF5050+|r",
	rare = format("|cffAF5050 %s|r", ITEM_QUALITY3_DESC)
}

--THE ID LINE, in one place.
--
--Nineteen call sites used to inline `format("|cFFCA3C3C%s|r %d", ID, id)`, and format RAISES
--on a nil id rather than skipping the line -- so the whole spellID feature took down whatever
--was drawing the tooltip whenever a link did not parse. Reported 2026-08-09 on inspecting a
--player: Turtle's transmog UI calls SetHyperlink with a bare `item:12345`, which the `(%d+):`
--pattern cannot match because there is no colon AFTER the digits, and the error came back out
--through InspectPaperDollFrame.
--
--An id we cannot parse should cost the ID line and nothing else.
local function AddID(tt, id)
	id = tonumber(id)
	if not (tt and id) then return end

	--The ONLY remaining inline format of this line, deliberately. A blanket replace of the
	--old expression rewrote this body into a call to itself and every tooltip recursed until
	--the stack blew; keep this the one place the string is built.
	tt:AddLine(format("|cFFCA3C3C%s|r %d", ID, id))
end

function TT:GameTooltip_SetDefaultAnchor(tt, parent)
	if E.private.tooltip.enable ~= true then return end
	if tt:GetAnchorType() ~= "ANCHOR_NONE" then return end

	if parent then
		if self.db.healthBar.statusPosition == "BOTTOM" then
			if GameTooltipStatusBar.anchoredToTop then
				GameTooltipStatusBar:ClearAllPoints()
				E:Point(GameTooltipStatusBar, "TOPLEFT", GameTooltip, "BOTTOMLEFT", E.Border, -(E.Spacing * 3))
				E:Point(GameTooltipStatusBar, "TOPRIGHT", GameTooltip, "BOTTOMRIGHT", -E.Border, -(E.Spacing * 3))
				E:Point(GameTooltipStatusBar.text, "CENTER", GameTooltipStatusBar, 0, -3)
				GameTooltipStatusBar.anchoredToTop = nil
			end
		else
			if not GameTooltipStatusBar.anchoredToTop then
				GameTooltipStatusBar:ClearAllPoints()
				E:Point(GameTooltipStatusBar, "BOTTOMLEFT", GameTooltip, "TOPLEFT", E.Border, (E.Spacing * 3))
				E:Point(GameTooltipStatusBar, "BOTTOMRIGHT", GameTooltip, "TOPRIGHT", -E.Border, (E.Spacing * 3))
				E:Point(GameTooltipStatusBar.text, "CENTER", GameTooltipStatusBar, 0, 3)
				GameTooltipStatusBar.anchoredToTop = true
			end
		end
		if self.db.cursorAnchor then
			tt:SetOwner(parent, "ANCHOR_CURSOR")
			return
		else
			tt:SetOwner(parent, "ANCHOR_NONE")
		end
	end

	if not E:HasMoverBeenMoved("TooltipMover") then
		if ElvUI_ContainerFrame and ElvUI_ContainerFrame:IsShown() then
			E:Point(tt, "BOTTOMRIGHT", ElvUI_ContainerFrame, "TOPRIGHT", 0, 18)
		elseif RightChatPanel:GetAlpha() == 1 and RightChatPanel:IsShown() then
			E:Point(tt, "BOTTOMRIGHT", RightChatPanel, "TOPRIGHT", 0, 18)
		else
			E:Point(tt, "BOTTOMRIGHT", RightChatPanel, "BOTTOMRIGHT", 0, 18)
		end
	else
		local point = E:GetScreenQuadrant(TooltipMover)
		if point == "TOPLEFT" then
			tt:SetPoint("TOPLEFT", TooltipMover)
		elseif point == "TOPRIGHT" then
			tt:SetPoint("TOPRIGHT", TooltipMover)
		elseif point == "BOTTOMLEFT" or point == "LEFT" then
			tt:SetPoint("BOTTOMLEFT", TooltipMover)
		else
			tt:SetPoint("BOTTOMRIGHT", TooltipMover)
		end
	end
end

function TT:SetStyle(tt)
	E:SetTemplate(tt, "Transparent", nil, true)
	local r, g, b = tt:GetBackdropColor()
	tt:SetBackdropColor(r, g, b, self.db.colorAlpha)
end

function TT:RemoveTrashLines(tt)
	for i = 2, tt:NumLines() do
		local tiptext = _G["GameTooltipTextLeft"..i]
		local linetext = tiptext:GetText()

		--Same missing global as below; without PVP this comparison never matched,
		--so the PvP line was never detected
		if linetext == (PVP or HELPFRAME_HOME_ISSUE3_HEADER) or linetext == FACTION_ALLIANCE or linetext == FACTION_HORDE then
			tiptext:SetText(nil)
			tiptext:Hide()
		end
	end
end

function TT:GetLevelLine(tt, offset)
	for i = offset, tt:NumLines() do
		local tipText = _G["GameTooltipTextLeft"..i]
		if tipText:GetText() and find(tipText:GetText(), LEVEL) then
			return tipText
		end
	end
end

function TT:UPDATE_MOUSEOVER_UNIT(_, unit)
	if not unit then unit = "mouseover" end
	if not UnitExists(unit) then return end

	TT:RemoveTrashLines(GameTooltip)
	local level = UnitLevel(unit)

	local color
	if UnitIsPlayer(unit) then
		local localeClass, class = UnitClass(unit)
		local name = UnitName(unit)
		local guildName, guildRankName = GetGuildInfo(unit)
		if not localeClass or not class then return end

		color = CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class] or RAID_CLASS_COLORS[class]

		GameTooltipTextLeft1:SetText(format("%s%s", E:RGBToHex(color.r, color.g, color.b), name))

		local diffColor = GetQuestDifficultyColor(level)
		local race = UnitRace(unit)

		if guildName then
			if self.db.guildRanks then
				GameTooltipTextLeft2:SetText(format("<|cff00ff10%s|r> [|cff00ff10%s|r]", guildName, guildRankName))
			else
				GameTooltipTextLeft2:SetText(format("<|cff00ff10%s|r>", guildName))
			end
			GameTooltip:AddLine(format("|cff%02x%02x%02x%s|r %s %s%s|r", diffColor.r * 255, diffColor.g * 255, diffColor.b * 255, level > 0 and level or "??", race or "", E:RGBToHex(color.r, color.g, color.b), localeClass), 1, 1, 1)
		else
			GameTooltipTextLeft2:SetText(format("|cff%02x%02x%02x%s|r %s %s%s|r", diffColor.r * 255, diffColor.g * 255, diffColor.b * 255, level > 0 and level or "??", race or "", E:RGBToHex(color.r, color.g, color.b), localeClass))
		end
	else
		if UnitIsTapped(unit) and not UnitIsTappedByPlayer(unit) then
			color = TAPPED_COLOR
		else
			color = E.db.tooltip.useCustomFactionColors and E.db.tooltip.factionColors[UnitReaction(unit, "player")] or FACTION_BAR_COLORS[UnitReaction(unit, "player")]
		end

		local levelLine = self:GetLevelLine(GameTooltip, 2)
		if levelLine then
			local creatureClassification = UnitClassification(unit)
			local creatureType = UnitCreatureType(unit)
			local pvpFlag = ""
			local diffColor = GetQuestDifficultyColor(level)

			if UnitIsPVP(unit) then
				--HELPFRAME_HOME_ISSUE3_HEADER is absent on this client, which made
				--format receive nil. PVP is the 1.12 global carrying the same label.
				pvpFlag = format(" (%s)", PVP or HELPFRAME_HOME_ISSUE3_HEADER or "PvP")
			end

			levelLine:SetText(format("|cff%02x%02x%02x%s|r%s %s%s", diffColor.r * 255, diffColor.g * 255, diffColor.b * 255, level > 0 and level or "??", classification[creatureClassification] or "", creatureType or "", pvpFlag))
		end
	end

	local unitTarget = unit.."target"
	if self.db.targetInfo and unit ~= "player" and UnitExists(unitTarget) then
		local targetColor
		if UnitIsPlayer(unitTarget) then
			local _, class = UnitClass(unitTarget)
			targetColor = CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class] or RAID_CLASS_COLORS[class]
		else
			local reaction = UnitReaction(unitTarget, "player") or 4
			targetColor = E.db.tooltip.useCustomFactionColors and E.db.tooltip.factionColors[reaction] or FACTION_BAR_COLORS[reaction]
		end

		GameTooltip:AddDoubleLine(format("%s:", TARGET), format("|cff%02x%02x%02x%s|r", targetColor.r * 255, targetColor.g * 255, targetColor.b * 255, UnitName(unitTarget)))
	end

	local numParty, numRaid = GetNumPartyMembers(), GetNumRaidMembers()
	if self.db.targetInfo and (numParty > 0 or numRaid > 0) then
		for i = 1, (numRaid > 0 and numRaid or numParty) do
			local groupUnit = (numRaid > 0 and "raid"..i or "party"..i)
			if UnitIsUnit(groupUnit.."target", unit) and (not UnitIsUnit(groupUnit,"player")) then
				local _, class = UnitClass(groupUnit)
				local color = CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class] or RAID_CLASS_COLORS[class]
				tinsert(targetList, format("%s%s", E:RGBToHex(color.r, color.g, color.b), UnitName(groupUnit)))
			end
		end
		local numList = getn(targetList)
		if numList > 0 then
			GameTooltip:AddLine(format("%s (|cffffffff%d|r): %s", L["Targeted By:"], numList, tconcat(targetList, ", ")), nil, nil, nil, true)
			twipe(targetList)
		end
	end

	if color then
		GameTooltipStatusBar:SetStatusBarColor(color.r, color.g, color.b)
	else
		GameTooltipStatusBar:SetStatusBarColor(0.6, 0.6, 0.6)
	end

	GameTooltip:Show()

	local textWidth = GameTooltipStatusBar.text:GetStringWidth()
	if textWidth then
		GameTooltip:SetMinimumWidth(textWidth)
	end
end

function TT:SetUnit(tt, unit)
	self:UPDATE_MOUSEOVER_UNIT(nil, unit)
end

function TT:GameTooltipStatusBar_OnValueChanged()
	if not arg1 or not self.db.healthBar.text or not this.text then return end

	local _, max = this:GetMinMaxValues()
	if arg1 > 0 and max == 1 then
		this.text:SetText(format("%d%%", floor(arg1 * 100)))
		this:SetStatusBarColor(TAPPED_COLOR.r, TAPPED_COLOR.g, TAPPED_COLOR.b) --most effeciant?
	elseif arg1 == 0 then
		this.text:SetText(DEAD)
	else
		this.text:SetText(E:ShortValue(arg1).." / "..E:ShortValue(max))
	end
end

function TT:SetItemRef(link)
	if find(link, "^item:") then
		if E.db.tooltip.spellID then
			local id = tonumber(match(link, "(%d+)"))
			AddID(ItemRefTooltip, id)
		end
	end
	ItemRefTooltip:Show()
end

function TT:SetPrice(tt, id, count)
	if not count then return end

	local price = LIP:GetSellValue(id)

	--The merchant window already prints what it will pay, so the sale price line stays
	--suppressed there. The auction comparison below is not: standing at a vendor with a
	--full bag is exactly when "list it or vendor it" gets asked.
	if price and price > 0 and not MerchantFrame:IsShown() then
		tt:AddDoubleLine(SALE_PRICE_COLON, E:FormatMoney(count and price * count or price, "BLIZZARD", false), nil, nil, nil, 1, 1, 1)
	end

	self:SetAuctionPrice(tt, id, count, price)
end

local AUCTION_STALE_AFTER = 7 * 86400

--Age in words, plus whether the reading is old enough to want colouring
--differently. A price is only as good as the day it was taken and there is no
--way for the tooltip to know the market has moved, so saying how old it is
--is the whole of the honesty available here.
local function AgeText(when)
	if not when then return "", false end

	local seconds = time() - when
	if seconds < 0 then seconds = 0 end

	local stale = seconds > AUCTION_STALE_AFTER

	if seconds < 3600 then return format(L["%dm ago"], floor(seconds / 60)), stale end
	if seconds < 86400 then return format(L["%dh ago"], floor(seconds / 3600)), stale end
	return format(L["%dd ago"], floor(seconds / 86400)), stale
end

--[[
	What the auction house is paying for this, next to what the vendor is paying.

	The question this answers is the one asked at a vendor with a full bag: is this worth
	the walk to the auctioneer, or is it three copper and a wasted trip. Both halves have
	to be on the same tooltip for that to be answerable at a glance.

	It only knows items a scan has actually seen -- Modules/Auction/Prices.lua writes
	E.global.auctionPrices from the page-walking scan in Modules/Auction/Scan.lua -- so
	this line is absent far more often than it is present. That is deliberate: an invented
	market price is worse than no market price. Scanning an item at the auction house is
	what makes it appear here, and /octoui-ah prices <name> is how to see what is stored
	without going and finding one of the items.

	THIS READS THE SAVED TABLE DIRECTLY rather than going through E:GetModule("Auction").
	Two reasons, and both are load-order facts rather than preferences. The tooltip module
	loads well before the auction module, so there is nothing to resolve at file scope; and
	the price database outlives the module that filled it -- somebody who installs aux, or
	switches OctoUI's own auction window off, keeps every reading they collected, and these
	lines keep working. The store is plain data and is documented as such in Prices.lua.

	EVERY FIELD EXCEPT unitBid AND unitBuyout IS TREATED AS OPTIONAL. Records banked before
	Prices.lua existed carry no market, stack or id, and a saved variable is not something
	to migrate on a login that never opened an auction house. Missing simply means the
	corresponding line is not drawn.

	The headline figure is the CHEAPEST per unit seen, which is what a seller would have to
	undercut, not an average -- and it is before the auction house's cut. The 1.2x
	threshold leaves room for that rather than pretending to model it. Measured 2026-08-07,
	THIS SERVER'S CUT IS ZERO, so the threshold is more conservative than it needs to be.
]]
function TT:SetAuctionPrice(tt, id, count, vendorPrice)
	if not E.db.tooltip.auctionPrice then return end
	if not (id and E.global and E.global.auctionPrices) then return end

	local name = GetItemInfo(id)
	if not name then return end

	local record = E.global.auctionPrices[name]
	if not record then return end

	--A reading old enough to mislead can be dropped outright rather than merely aged.
	--Zero, the default, never hides one: an old price with its age attached is still
	--information, and silently withholding what the player collected is worse than
	--showing it with a date on it.
	local maxAge = E.db.tooltip.auctionPriceMaxAge or 0
	if maxAge > 0 and record.when and (time() - record.when) > (maxAge * 86400) then return end

	--Prefer the buyout: it is what the item can be turned into gold for now. Fall back to
	--the bid only where nothing in that scan carried a buyout at all.
	local unit, label = record.unitBuyout, L["Auction (cheapest buyout)"]
	if not unit or unit <= 0 then
		unit, label = record.unitBid, L["Auction (cheapest bid)"]
	end
	if not unit or unit <= 0 then return end

	if count and count > 1 then
		tt:AddDoubleLine(label, format(L["AUCTION_TOOLTIP_STACK"],
			E:FormatMoney(unit, "SMART"), E:FormatMoney(unit * count, "SMART"), count),
			nil, nil, nil, 1, 0.82, 0)
	else
		tt:AddDoubleLine(label, format(L["AUCTION_TOOLTIP_EACH"], E:FormatMoney(unit, "SMART")),
			nil, nil, nil, 1, 0.82, 0)
	end

	--What the item typically goes for, next to what the cheapest one goes for. These are
	--different questions -- the cheapest is what a seller must beat, the typical is what
	--the market will bear -- and on a thin market they are the same number, so the line is
	--drawn only when it disagrees enough to be worth the row. 10% is the threshold: a
	--second line that repeats the first is noise on a tooltip already carrying four.
	--
	--IT MULTIPLIES BY THE SAME COUNT THE LINE ABOVE DOES, the stack in hand. The record
	--also knows the usual stack size on the auction house, and putting THAT here was the
	--first attempt -- it produces two adjacent lines reading "for 5" and "for 20", where
	--the reader has every reason to assume both totals are for the item they are holding.
	--Two figures that can be compared straight down the column is the whole point of the
	--second line. The usual stack size is in /octoui-ah prices instead.
	local market = record.market
	if market and market > 0 and market >= unit * 1.1 then
		if count and count > 1 then
			tt:AddDoubleLine(L["Auction (typical)"], format(L["AUCTION_TOOLTIP_STACK"],
				E:FormatMoney(market, "SMART"), E:FormatMoney(market * count, "SMART"), count),
				nil, nil, nil, 0.85, 0.7, 0.45)
		else
			tt:AddDoubleLine(L["Auction (typical)"],
				format(L["AUCTION_TOOLTIP_EACH"], E:FormatMoney(market, "SMART")),
				nil, nil, nil, 0.85, 0.7, 0.45)
		end
	end

	--The footer carries how old the reading is and how much of a market it was taken
	--from. One auction seen is a price; forty is a market, and the difference decides how
	--much weight to give the two lines above it.
	local age, stale = AgeText(record.when)
	if record.seen and record.seen > 0 then
		age = format(L["AUCTION_TOOLTIP_SEEN"], age, record.seen)
	end

	local ar, ag, ab = 0.6, 0.6, 0.6
	if stale then ar, ag, ab = 0.85, 0.6, 0.3 end

	if vendorPrice and vendorPrice > 0 then
		local ratio = unit / vendorPrice
		local verdict, r, g, b

		if ratio >= 1.2 then
			verdict, r, g, b = format(L["AUCTION_TOOLTIP_LIST_IT"], ratio), 0.2, 1, 0.2
		elseif ratio > 1 then
			verdict, r, g, b = format(L["AUCTION_TOOLTIP_MARGINAL"], ratio), 1, 0.82, 0
		else
			verdict, r, g, b = L["AUCTION_TOOLTIP_VENDOR_IT"], 1, 0.5, 0.1
		end

		tt:AddDoubleLine(age, verdict, ar, ag, ab, r, g, b)
	else
		tt:AddDoubleLine(age, "", ar, ag, ab)
	end
end

function TT:SetAction(tt, buttonID)
	if GameTooltipTextRight1:IsShown() then return end
	local itemName = GameTooltipTextLeft1:GetText()
	if not itemName then return end

	local item, link = GetItemInfoByName(itemName)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local count = 1
		if IsConsumableAction(buttonID) then
			local actionCount = GetActionCount(buttonID)
			if actionCount and actionCount == GetItemCount(item) then
				count = actionCount
			end
		end

		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetAuctionItem(tt, type, index)
	local link = GetAuctionItemLink(type, index)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetAuctionItemInfo(type, index)
		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetAuctionSellItem(tt)
	local name, _, count = GetAuctionSellItemInfo()
	local _, link = GetItemInfoByName(name)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetBagItem(tt, bag, slot)
	local link = GetContainerItemLink(bag, slot)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, count = GetContainerItemInfo(bag, slot)
		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetCraftItem(tt, skill, slot)
	local link = slot and GetCraftReagentItemLink(skill, slot) or GetCraftItemLink(GetCraftSelectionIndex())
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local count = 1
		if slot then
			count = select(3, GetCraftReagentInfo(skill, slot))
		end

		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetCraftSpell(tt, id)
	local link = GetCraftItemLink(id)
	if not link then return end

	local id = tonumber(match(link, "enchant:(%d+)"))

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetHyperlink(tt, link, count)
	if not link then return end

	--`(%d+):` needs a colon AFTER the digits, so it only matches a full link like
	--`item:12345:0:0:0` and fails on the bare `item:12345` that Turtle's transmog UI passes
	--in. Ask for the id by its prefix first, the way SetInboxItem and SetCraftSpell already
	--do, and keep the old pattern last so nothing that used to resolve stops resolving.
	local id = tonumber(match(link, "item:(%d+)"))
		or tonumber(match(link, "spell:(%d+)"))
		or tonumber(match(link, "enchant:(%d+)"))
		or tonumber(match(link, "(%d+):"))

	if E.db.tooltip.itemPrice then
		count = tonumber(count)
		if not count or count < 1 then
			local owner = tt:GetParent()
			count = owner and tonumber(owner.count)
			if not count or count < 1 then
				count = 1
			end
		end
		self:SetPrice(tt, id, count)
	end

	if tt:GetName() == "GameTooltip" then
		if E.db.tooltip.spellID then
			AddID(tt, id)
		end
	end

	tt:Show()
end

function TT:SetInboxItem(tt, index, attachmentIndex)
	local name, _, count = GetInboxItem(index, attachmentIndex)
	local _, link = GetItemInfoByName(name)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetInventoryItem(tt, unit, slot)
	if type(slot) ~= "number" or slot < 0 then return end

	local link = GetInventoryItemLink(unit, slot)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local count = 1
		if slot < 20 or slot > 39 and slot < 68 then
			count = GetInventoryItemCount(unit, slot)
		end

		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetLootItem(tt, slot)
	local link = GetLootSlotLink(slot)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetLootSlotInfo(slot)
		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetLootRollItem(tt, rollID)
	local link = GetLootRollItemLink(rollID)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetLootRollItemInfo(rollID)
		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetMerchantItem(tt, slot)
	local link = GetMerchantItemLink(slot)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, _, count = GetMerchantItemInfo(slot)
		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetQuestItem(tt, type, slot)
	local link = GetQuestItemLink(type, slot)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetQuestItemInfo(type, slot)
		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetQuestLogItem(tt, type, index)
	local link = GetQuestLogItemLink(type, index)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetQuestLogRewardInfo(index)
		self:SetPrice(tt, id, count)
	end
	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetSendMailItem(tt, index)
	local name, _, count = GetSendMailItem(index)
	local _, link = GetItemInfoByName(name)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetTradePlayerItem(tt, index)
	local link = GetTradePlayerItemLink(index)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetTradePlayerItemInfo(index)
		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetTradeSkillItem(tt, skill, slot)
	local link = slot and GetTradeSkillReagentItemLink(skill, slot) or GetTradeSkillItemLink(skill)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local id = tonumber(match(link, "item:(%d+)"))
		local count = 1
		if slot then
			count = select(3, GetTradeSkillReagentInfo(skill, slot))
		end

		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:SetTradeTargetItem(tt, index)
	local link = GetTradeTargetItemLink(index)
	if not link then return end

	local id = tonumber(match(link, "item:(%d+)"))

	if E.db.tooltip.itemPrice then
		local _, _, count = GetTradeTargetItemInfo(index)
		self:SetPrice(tt, id, count)
	end

	if E.db.tooltip.spellID then
		AddID(tt, id)
	end
	tt:Show()
end

function TT:Show()
	return
end

function TT:CheckBackdropColor()
	if not this:IsShown() then return end

	local r, g, b = this:GetBackdropColor()
	if r and g and b then
		r = E:Round(r, 1)
		g = E:Round(g, 1)
		b = E:Round(b, 1)
		local red, green, blue = unpack(E.media.backdropfadecolor)
		if r ~= red or g ~= green or b ~= blue then
			this:SetBackdropColor(red, green, blue, self.db.colorAlpha)
			this:SetBackdropBorderColor(unpack(E.media.bordercolor))
		end
	end
end

function TT:SetTooltipFonts()
	local font = E.LSM:Fetch("font", E.db.tooltip.font)
	local fontOutline = E.db.tooltip.fontOutline
	local headerSize = E.db.tooltip.headerFontSize
	local textSize = E.db.tooltip.textFontSize
	local smallTextSize = E.db.tooltip.smallTextFontSize

	GameTooltipHeaderText:SetFont(font, headerSize, fontOutline)
	GameTooltipText:SetFont(font, textSize, fontOutline)
	GameTooltipTextSmall:SetFont(font, smallTextSize, fontOutline)
	if GameTooltip.hasMoney then
		for i = 1, GameTooltip.numMoneyFrames do
			_G["GameTooltipMoneyFrame"..i.."PrefixText"]:SetFont(font, textSize, fontOutline)
			_G["GameTooltipMoneyFrame"..i.."SuffixText"]:SetFont(font, textSize, fontOutline)
			_G["GameTooltipMoneyFrame"..i.."GoldButtonText"]:SetFont(font, textSize, fontOutline)
			_G["GameTooltipMoneyFrame"..i.."SilverButtonText"]:SetFont(font, textSize, fontOutline)
			_G["GameTooltipMoneyFrame"..i.."CopperButtonText"]:SetFont(font, textSize, fontOutline)
		end
	end

	ShoppingTooltip1TextLeft1:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextLeft2:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextLeft3:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextLeft4:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextRight1:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextRight2:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextRight3:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip1TextRight4:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextLeft1:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextLeft2:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextLeft3:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextLeft4:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextRight1:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextRight2:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextRight3:SetFont(font, headerSize, fontOutline)
	ShoppingTooltip2TextRight4:SetFont(font, headerSize, fontOutline)
end

function TT:Initialize()
	self.db = E.db.tooltip

	if E.private.tooltip.enable ~= true then return end
	E.Tooltip = TT

	E:Height(GameTooltipStatusBar, self.db.healthBar.height)
	GameTooltipStatusBar:SetScript("OnValueChanged", nil)
	GameTooltipStatusBar.text = GameTooltipStatusBar:CreateFontString(nil, "OVERLAY")
	E:Point(GameTooltipStatusBar.text, "CENTER", GameTooltipStatusBar, 0, -3)
	E:FontTemplate(GameTooltipStatusBar.text, E.LSM:Fetch("font", self.db.healthBar.font), self.db.healthBar.fontSize, self.db.healthBar.fontOutline)

	if not GameTooltip.hasMoney then
		SetTooltipMoney(GameTooltip, 1, nil, "", "")
		SetTooltipMoney(GameTooltip, 1, nil, "", "")
		GameTooltipMoneyFrame:Hide()
	end
	self:SetTooltipFonts()

	self:SecureHook("GameTooltip_SetDefaultAnchor")
	self:SecureHook("SetItemRef")

	self:SecureHook(ItemRefTooltip, "SetHyperlink", "SetHyperlink")

	self:SecureHook(GameTooltip, "SetUnit")

	self:SecureHook(GameTooltip, "SetAction", "SetAction")
	self:SecureHook(GameTooltip, "SetAuctionItem", "SetAuctionItem")
	self:SecureHook(GameTooltip, "SetAuctionSellItem", "SetAuctionSellItem")
	self:SecureHook(GameTooltip, "SetBagItem", "SetBagItem")
	self:SecureHook(GameTooltip, "SetCraftItem", "SetCraftItem")
	self:SecureHook(GameTooltip, "SetCraftSpell", "SetCraftSpell")
	self:SecureHook(GameTooltip, "SetHyperlink", "SetHyperlink")
	self:SecureHook(GameTooltip, "SetInboxItem", "SetInboxItem")
	self:SecureHook(GameTooltip, "SetInventoryItem", "SetInventoryItem")
	self:SecureHook(GameTooltip, "SetLootItem", "SetLootItem")
	self:SecureHook(GameTooltip, "SetLootRollItem", "SetLootRollItem")
	self:SecureHook(GameTooltip, "SetMerchantItem", "SetMerchantItem")
	self:SecureHook(GameTooltip, "SetQuestItem", "SetQuestItem")
	self:SecureHook(GameTooltip, "SetQuestLogItem", "SetQuestLogItem")
	self:SecureHook(GameTooltip, "SetSendMailItem", "SetSendMailItem")
	self:SecureHook(GameTooltip, "SetTradePlayerItem", "SetTradePlayerItem")
	self:SecureHook(GameTooltip, "SetTradeSkillItem", "SetTradeSkillItem")
	self:SecureHook(GameTooltip, "SetTradeTargetItem", "SetTradeTargetItem")
	self:SecureHook(GameTooltip, "Show", "Show")

	self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")

	self:HookScript(GameTooltipStatusBar, "OnValueChanged", "GameTooltipStatusBar_OnValueChanged")
end

local function InitializeCallback()
	TT:Initialize()
end

E:RegisterModule(TT:GetName(), InitializeCallback)