local E, L, V, P, G = unpack(ElvUI)
local mod = E:GetModule("NamePlates")
local LSM = LibStub("LibSharedMedia-3.0")

local pairs, select, unpack = pairs, select, unpack
local gsub = string.gsub
local tinsert, tremove, wipe = table.insert, table.remove, table.wipe

local CreateFrame = CreateFrame
local UnitBuff = UnitBuff
local UnitDebuff = UnitDebuff
local UnitExists = UnitExists
local UnitName = UnitName

--[[
	1.12 has no COMBAT_LOG_EVENT_UNFILTERED and no UnitAura with durations, so the
	upstream aura cache (fed by the combat log, keyed by GUID) can never fill here.
	Auras are read straight off the unit instead, which needs a unit token per plate:

		SuperWoW   -> the plate's parent frame carries the unit GUID, GetName(1).
		              Every Unit* function accepts that GUID as a unit token, so each
		              mob is addressed individually and same-name mobs never mirror.
		no SuperWoW-> only "target" and "mouseover" can be resolved, so only those
		              two plates can show auras.

	UnitBuff/UnitDebuff return texture and stack count only. There is no duration
	source on this client, so icons carry no timer and are driven purely by whether
	the aura is still on the unit at the next poll.
]]

local MAX_UNIT_AURAS = 16 -- 1.12 exposes at most 16 buffs and 16 debuffs per unit
local AURA_NAME_PATTERN = "%s*%(%*%)$" -- some clients suffix duplicated plate names

local auraCache = {}

local scanner, scannerLine
local function GetAuraName(unit, index, isDebuff)
	if not scanner then
		scanner = CreateFrame("GameTooltip", "ElvUI_NamePlateAuraScanner", nil, "GameTooltipTemplate")
		scannerLine = _G["ElvUI_NamePlateAuraScannerTextLeft1"]
	end

	scanner:SetOwner(E.UIParent, "ANCHOR_NONE")
	scanner:ClearLines()

	if isDebuff then
		scanner:SetUnitDebuff(unit, index)
	else
		scanner:SetUnitBuff(unit, index)
	end

	return scannerLine and scannerLine:GetText()
end

--Tooltip scans are expensive, so only redo one when the icon at that slot changed
local function GetCachedAuraName(auras, unit, index, texture, isDebuff)
	if auras.nameTexture[index] ~= texture then
		auras.nameTexture[index] = texture
		auras.nameCache[index] = GetAuraName(unit, index, isDebuff)
	end

	return auras.nameCache[index]
end

local function GetAuraFilter(db)
	local filterName = db.filters and db.filters.filter
	if not filterName or filterName == "" then return end

	return E.global["unitframe"]["aurafilters"][filterName]
end

local function PassesFilter(trackFilter, name)
	if not trackFilter then return true end

	local spell = name and trackFilter.spells and trackFilter.spells[name]
	if trackFilter.type == "Whitelist" then
		return (spell and spell.enable) and true or false
	elseif trackFilter.type == "Blacklist" then
		return not (spell and spell.enable)
	end

	return true
end

function mod:CleanAuraLists()
	for frame in pairs(self.CreatedPlates) do
		local plate = frame.UnitFrame
		if plate then
			if plate.Buffs then
				wipe(plate.Buffs.nameCache)
				wipe(plate.Buffs.nameTexture)
			end
			if plate.Debuffs then
				wipe(plate.Debuffs.nameCache)
				wipe(plate.Debuffs.nameTexture)
			end
		end
	end
end

--Resolve a unit token for this plate. Prefer the SuperWoW GUID: it is per-mob, so
--two mobs sharing a name get their own auras instead of mirroring each other.
function mod:GetPlateUnit(frame)
	if self.superwow then
		local parent = frame:GetParent()
		local guid = parent and parent:GetName(1)
		if guid and guid ~= "" and UnitExists(guid) then
			--the plate/GUID pairing lags by a frame right after a target switch
			local plateName = frame.UnitName and gsub(frame.UnitName, AURA_NAME_PATTERN, "")
			if not plateName or plateName == UnitName(guid) then
				return guid
			end
		end
	end

	if frame.isTarget and UnitExists("target") then
		return "target"
	elseif frame.isMouseover and UnitExists("mouseover") then
		return "mouseover"
	end
end

function mod:SetAura(aura, texture, count, name)
	aura.icon:SetTexture(texture)
	aura.name = name

	if count and count > 1 then
		aura.count:SetText(count)
	else
		aura.count:SetText("")
	end

	aura:Show()
end

function mod:HideAuraIcons(auras)
	if not (auras and auras.icons) then return end

	for i = 1, getn(auras.icons) do
		auras.icons[i].name = nil
		auras.icons[i]:Hide()
	end
end

function mod:UpdateAuraSide(auras, unit, isDebuff)
	self:HideAuraIcons(auras)

	local db = auras.db
	if not (unit and db and db.enable) then return false end

	local maxIcons = getn(auras.icons)
	if maxIcons == 0 then return false end

	local trackFilter = GetAuraFilter(db)
	local needName = trackFilter or self.StyleFilterCheckAuras
	local frameNum = 1

	for index = 1, MAX_UNIT_AURAS do
		if frameNum > maxIcons then break end

		local texture, count
		if isDebuff then
			texture, count = UnitDebuff(unit, index)
		else
			texture, count = UnitBuff(unit, index)
		end

		--the client returns auras contiguously, so the first gap is the end of the list
		if not texture then break end

		local name
		if needName then
			name = GetCachedAuraName(auras, unit, index, texture, isDebuff)
		end

		if PassesFilter(trackFilter, name) then
			self:SetAura(auras.icons[frameNum], texture, count, name)
			frameNum = frameNum + 1
		end
	end

	return frameNum > 1
end

function mod:UpdateElement_Auras(frame)
	if not frame.UnitType then return end
	if not frame.HealthBar:IsShown() then return end

	local unit = self:GetPlateUnit(frame)
	frame.guid = (unit and unit ~= "target" and unit ~= "mouseover") and unit or nil

	local hasDebuffs = self:UpdateAuraSide(frame.Debuffs, unit, true)
	local hasBuffs = self:UpdateAuraSide(frame.Buffs, unit, false)

	local TopLevel = frame.HealthBar
	--this runs on a timer now, so it can land before ConfigureElement_Name has
	--given the fontstring a font
	local nameHeight = select(2, frame.Name:GetFont())
	local TopOffset = (self.db.units[frame.UnitType].showName and nameHeight and (nameHeight + 5)) or 0
	if hasDebuffs then
		TopOffset = TopOffset + 3
		frame.Debuffs:SetPoint("BOTTOMLEFT", TopLevel, "TOPLEFT", 0, TopOffset)
		frame.Debuffs:SetPoint("BOTTOMRIGHT", TopLevel, "TOPRIGHT", 0, TopOffset)
		TopLevel = frame.Debuffs
		TopOffset = 3
	end

	if hasBuffs then
		if not hasDebuffs then
			TopOffset = TopOffset + 3
		end
		frame.Buffs:SetPoint("BOTTOMLEFT", TopLevel, "TOPLEFT", 0, TopOffset)
		frame.Buffs:SetPoint("BOTTOMRIGHT", TopLevel, "TOPRIGHT", 0, TopOffset)
		TopLevel = frame.Buffs
		TopOffset = 3
	end

	if frame.TopLevelFrame ~= TopLevel then
		frame.TopLevelFrame = TopLevel
		frame.TopOffset = TopOffset
	end
end

function mod:CreateAuraIcon(parent)
	local aura = CreateFrame("Frame", nil, parent)
	self:StyleFrame(aura, true)

	aura.icon = aura:CreateTexture(nil, "OVERLAY")
	aura.icon:SetAllPoints()
	aura.icon:SetTexCoord(unpack(E.TexCoords))

	aura.count = aura:CreateFontString(nil, "OVERLAY")
	aura.count:SetPoint("BOTTOMRIGHT", 0, 0)
	aura.count:SetFont(LSM:Fetch("font", self.db.font), self.db.fontSize, self.db.fontOutline)

	return aura
end

function mod:UpdateAuraIcons(auras)
	local frame = auras:GetParent()
	if not frame.UnitType then return end

	local db = auras.db
	local maxAuras = (db and db.enable and db.numAuras) or 0
	local numCurrentAuras = getn(auras.icons)

	if numCurrentAuras > maxAuras then
		for i = numCurrentAuras, maxAuras + 1, -1 do
			if auras.icons[i] then
				auras.icons[i]:Hide()
				tinsert(auraCache, auras.icons[i])
			end
			auras.icons[i] = nil
		end
	end

	if maxAuras == 0 then
		auras:SetWidth(1)
		return
	end

	--OnSizeChanged handlers get no self on 1.12, so size the icons here instead
	local scale = (frame.HealthBar and frame.HealthBar.currentScale) or 1
	local height = (db.baseHeight or 18) * scale
	local width = self.db.units[frame.UnitType].healthbar.width
	local spacing = E.Border + E.Spacing * 3

	auras:SetWidth(width)
	auras:SetHeight(height)

	--the row spans the health bar, but never let an icon go wider than it is tall:
	--stretched icons look wrong and the row simply ends short of the bar instead
	local iconWidth = (width - (spacing * (maxAuras - 1))) / maxAuras
	if not E.private.general.pixelPerfect then
		iconWidth = iconWidth - 3
	end
	if iconWidth > height then iconWidth = height end
	if iconWidth < 1 then iconWidth = 1 end

	for i = 1, maxAuras do
		auras.icons[i] = auras.icons[i] or tremove(auraCache) or mod:CreateAuraIcon(auras)
		auras.icons[i]:SetParent(auras)
		auras.icons[i]:ClearAllPoints()
		auras.icons[i]:Hide()
		auras.icons[i]:SetWidth(iconWidth)
		auras.icons[i]:SetHeight(height)

		if auras.side == "LEFT" then
			if i == 1 then
				auras.icons[i]:SetPoint("BOTTOMLEFT", auras, "BOTTOMLEFT")
			else
				auras.icons[i]:SetPoint("LEFT", auras.icons[i-1], "RIGHT", spacing, 0)
			end
		else
			if i == 1 then
				auras.icons[i]:SetPoint("BOTTOMRIGHT", auras, "BOTTOMRIGHT")
			else
				auras.icons[i]:SetPoint("RIGHT", auras.icons[i-1], "LEFT", -spacing, 0)
			end
		end
	end
end

function mod:ConstructElement_Auras(frame, side)
	local auras = CreateFrame("Frame", nil, frame)

	auras:SetWidth(1)
	auras:SetHeight(18)
	auras.side = side
	auras.icons = {}
	auras.nameCache = {}
	auras.nameTexture = {}

	return auras
end
