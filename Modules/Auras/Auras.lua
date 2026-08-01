local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:NewModule("Auras", "AceEvent-3.0");
local LSM = LibStub("LibSharedMedia-3.0");

--Cache global variables
--Lua functions
local _G = _G
local unpack, select, pairs, ipairs, next = unpack, select, pairs, ipairs, next
local floor, min, max, huge = math.floor, math.min, math.max, math.huge
local format = string.format
local getn, wipe, tinsert, tsort, tremove = table.getn, table.wipe, table.insert, table.sort, table.remove
--WoW API / Variables
local CreateFrame = CreateFrame
local GetInventoryItemQuality = GetInventoryItemQuality
local GetItemQualityColor = GetItemQualityColor
local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local GetInventoryItemTexture = GetInventoryItemTexture
local GetPlayerBuff = GetPlayerBuff
local GetPlayerBuffTexture = GetPlayerBuffTexture
local GetPlayerBuffApplications = GetPlayerBuffApplications
local GetPlayerBuffDispelType = GetPlayerBuffDispelType
local GetPlayerBuffTimeLeft = GetPlayerBuffTimeLeft

local DIRECTION_TO_POINT = {
	DOWN_RIGHT = "TOPLEFT",
	DOWN_LEFT = "TOPRIGHT",
	UP_RIGHT = "BOTTOMLEFT",
	UP_LEFT = "BOTTOMRIGHT",
	RIGHT_DOWN = "TOPLEFT",
	RIGHT_UP = "BOTTOMLEFT",
	LEFT_DOWN = "TOPRIGHT",
	LEFT_UP = "BOTTOMRIGHT"
}

local DIRECTION_TO_HORIZONTAL_SPACING_MULTIPLIER = {
	DOWN_RIGHT = 1,
	DOWN_LEFT = -1,
	UP_RIGHT = 1,
	UP_LEFT = -1,
	RIGHT_DOWN = 1,
	RIGHT_UP = 1,
	LEFT_DOWN = -1,
	LEFT_UP = -1
}

local DIRECTION_TO_VERTICAL_SPACING_MULTIPLIER = {
	DOWN_RIGHT = -1,
	DOWN_LEFT = -1,
	UP_RIGHT = 1,
	UP_LEFT = 1,
	RIGHT_DOWN = -1,
	RIGHT_UP = 1,
	LEFT_DOWN = -1,
	LEFT_UP = 1
}

local IS_HORIZONTAL_GROWTH = {
	RIGHT_DOWN = true,
	RIGHT_UP = true,
	LEFT_DOWN = true,
	LEFT_UP = true
}

function A:UpdateTime(elapsed)
	if self.offset then
		local expiration = select(self.offset, GetWeaponEnchantInfo())
		if expiration then
			self.timeLeft = expiration / 1e3
		else
			self.timeLeft = 0
		end
	else
		self.timeLeft = GetPlayerBuffTimeLeft(self.index)
	end

	if self.nextUpdate > 0 then
		self.nextUpdate = not self.offset and self.nextUpdate - elapsed or 1
		return
	end

	local timerValue, formatID
	timerValue, formatID, self.nextUpdate = E:GetTimeInfo(self.timeLeft, A.db.fadeThreshold)
	self.time:SetText(format("%s%s|r", E.TimeColors[formatID], format(E.TimeFormats[formatID][2], timerValue)))

	if self.timeLeft > E.db.auras.fadeThreshold then
	--	E:StopFlash(self)
	else
	--	E:Flash(self, 1)
	end
end

local function UpdateTooltip()
	if this.offset then
		GameTooltip:SetInventoryItem("player", this.offset == 2 and 16 or 17)
	else
		GameTooltip:SetPlayerBuff(this.index)
	end
end

local function OnEnter(self)
	if not self:IsVisible() then return end

	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT", -5, -5)
	self:UpdateTooltip()
end

local function OnLeave()
	GameTooltip:Hide()
end

local function OnClick(self)
	if self.index and self.index >= 0 then
		CancelPlayerBuff(self.index)
	end
end

function A:CreateIcon(button)
	local font = LSM:Fetch("font", self.db.font)
	button:RegisterForClicks("RightButtonUp")

	button.texture = button:CreateTexture(nil, "BORDER")
	E:SetInside(button.texture)
	button.texture:SetTexCoord(unpack(E.TexCoords))

	button.count = button:CreateFontString(nil, "ARTWORK")
	button.count:SetPoint("BOTTOMRIGHT", -1 + self.db.countXOffset, 1 + self.db.countYOffset)
	E:FontTemplate(button.count, font, self.db.fontSize, self.db.fontOutline)

	button.time = button:CreateFontString(nil, "ARTWORK")
	button.time:SetPoint("TOP", button, "BOTTOM", 1 + self.db.timeXOffset, 0 + self.db.timeYOffset)
	E:FontTemplate(button.time, font, self.db.fontSize, self.db.fontOutline)

	button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
	button.highlight:SetTexture(1, 1, 1, 0.45)
	E:SetInside(button.highlight)

	button.UpdateTooltip = UpdateTooltip
	button:SetScript("OnEnter", function() OnEnter(this) end)
	button:SetScript("OnLeave", function() OnLeave() end)
	button:SetScript("OnClick", function() OnClick(this) end)

	E:SetTemplate(button, "Default")
end

local enchantableSlots = {
  [1] = 16,
  [2] = 17
}

local buttons = {}
function A:ConfigureAuras(header, auraTable, weaponPosition)
	local headerName = header:GetName()

	local db = self.db.debuffs
	if header.filter == "HELPFUL" then
		db = self.db.buffs
	end

	local size = db.size
	local point = DIRECTION_TO_POINT[db.growthDirection]
	local xOffset = 0
	local yOffset = 0
	local wrapXOffset = 0
	local wrapYOffset = 0
	local wrapAfter = db.wrapAfter
	local maxWraps = db.maxWraps
	local minWidth = 0
	local minHeight = 0

	if IS_HORIZONTAL_GROWTH[db.growthDirection] then
		minWidth = ((wrapAfter == 1 and 0 or db.horizontalSpacing) + size) * wrapAfter
		minHeight = (db.verticalSpacing + size) * maxWraps
		xOffset = DIRECTION_TO_HORIZONTAL_SPACING_MULTIPLIER[db.growthDirection] * (db.horizontalSpacing + size)
		yOffset = 0
		wrapXOffset = 0
		wrapYOffset = DIRECTION_TO_VERTICAL_SPACING_MULTIPLIER[db.growthDirection] * (db.verticalSpacing + size)
	else
		minWidth = (db.horizontalSpacing + size) * maxWraps
		minHeight = ((wrapAfter == 1 and 0 or db.verticalSpacing) + size) * wrapAfter
		xOffset = 0
		yOffset = DIRECTION_TO_VERTICAL_SPACING_MULTIPLIER[db.growthDirection] * (db.verticalSpacing + size)
		wrapXOffset = DIRECTION_TO_HORIZONTAL_SPACING_MULTIPLIER[db.growthDirection] * (db.horizontalSpacing + size)
		wrapYOffset = 0
	end

	wipe(buttons)
	local button
	local numWeapon = 0
	if weaponPosition then
		local hasMainHandEnchant, mainHandExpiration, _, hasOffHandEnchant, offHandExpiration = GetWeaponEnchantInfo()
		for weapon = 2, 1, -1 do
			button = _G["ElvUIPlayerBuffsTempEnchant"..weapon]
			if select(weapon, hasMainHandEnchant, hasOffHandEnchant) then
				numWeapon = numWeapon + 1
				if not button then
					button = CreateFrame("Button", "$parentTempEnchant"..weapon, header)
					self:CreateIcon(button)
				end
				if button then
					if button:IsShown() then button:Hide() end

					local index = enchantableSlots[weapon]
					local quality = GetInventoryItemQuality("player", index)
					button.texture:SetTexture(GetInventoryItemTexture("player", index))

					if quality then
						button:SetBackdropBorderColor(GetItemQualityColor(quality))
					end

					local expirationTime = select(weapon, mainHandExpiration, offHandExpiration)
					if expirationTime then
						button.offset = select(weapon, 2, 5)
						button:SetScript("OnUpdate", function() self.UpdateTime(this, arg1) end)
						button.nextUpdate = -1
						A.UpdateTime(button, 0)
					else
						button.timeLeft = nil
						button.offset = nil
						button:SetScript("OnUpdate", nil)
						button.time:SetText("")
					end
					buttons[weapon] = button
				end
			else
				if button and type(button.Hide) == "function" then
					button.offset = nil
					button:Hide()
				end
			end
		end
	end

	for i = 1, getn(auraTable) do
		button = _G[headerName.."AuraButton"..i]
		if button then
			if button:IsShown() then button:Hide() end
		else
			button = CreateFrame("Button", "$parentAuraButton"..i, header)
			self:CreateIcon(button)
		end
		local buffInfo = auraTable[i]
		button.index = buffInfo.index

		if buffInfo.expires and buffInfo.expires > 0 then
			local timeLeft = buffInfo.expires
			if not button.timeLeft then
				button.timeLeft = timeLeft
				button:SetScript("OnUpdate", function() self.UpdateTime(this, arg1) end)
			else
				button.timeLeft = timeLeft
			end

			button.nextUpdate = -1
			self.UpdateTime(button, 0)
		else
			button.timeLeft = nil
			button.time:SetText("")
			button:SetScript("OnUpdate", nil)
		end

		if buffInfo.count > 1 then
			button.count:SetText(buffInfo.count)
		else
			button.count:SetText("")
		end

		if buffInfo.filter == "HARMFUL" then
			local color = DebuffTypeColor[buffInfo.dispelType or ""] or DebuffTypeColor.none
			button:SetBackdropBorderColor(color.r, color.g, color.b)
		else
			button:SetBackdropBorderColor(unpack(E.media.bordercolor))
		end

		button.texture:SetTexture(buffInfo.icon)

		buttons[i+numWeapon] = button
	end

	--NOT getn(buttons). `buttons` is filled by direct index assignment, and table.wipe
	--above calls setn(t, 0) -- so in Lua 5.0 getn hands back the stored n of 0 rather than
	--counting, display came out 0, and the loop below never ran once. Every button was
	--created and none was ever positioned or shown, which is why these panels have never
	--appeared. Same hidden-n trap as the `t[getn(t)] = nil` infinite loop at the top of
	--HANDOFF.md: only table.insert and table.remove maintain n.
	local display = numWeapon + getn(auraTable)
	if wrapAfter and maxWraps then
		display = min(display, wrapAfter * maxWraps)
	end

	local left, right, top, bottom = huge, -huge, -huge, huge
	for index = 1, display do
		button = buttons[index]
		--An off-hand enchant with no main-hand one leaves a hole: the weapon loop stores
		--by weapon slot, so buttons[2] is set while buttons[1] is not, and the aura
		--buttons start at numWeapon + 1 regardless. Skip rather than index a nil frame.
		if button then
			local tick, cycle = floor(mod((index - 1), wrapAfter)), floor((index - 1) / wrapAfter)
			button:ClearAllPoints()
			button:SetPoint(point, header, cycle * wrapXOffset + tick * xOffset, cycle * wrapYOffset + tick * yOffset)

			button:SetWidth(size)
			button:SetHeight(size)

			if button.time then
				local font = LSM:Fetch("font", self.db.font)
				button.time:ClearAllPoints()
				button.time:SetPoint("TOP", button, "BOTTOM", 1 + self.db.timeXOffset, 0 + self.db.timeYOffset)
				E:FontTemplate(button.time, font, self.db.fontSize, self.db.fontOutline)

				button.count:ClearAllPoints()
				button.count:SetPoint("BOTTOMRIGHT", -1 + self.db.countXOffset, 0 + self.db.countYOffset)
				E:FontTemplate(button.count, font, self.db.fontSize, self.db.fontOutline)
			end

			button:Show()
			left = min(left, button:GetLeft() or huge)
			right = max(right, button:GetRight() or -huge)
			top = max(top, button:GetTop() or -huge)
			bottom = min(bottom, button:GetBottom() or huge)
		end
	end

	--Aura buttons are named AuraButton1..getn(auraTable); the temp enchant ones are named
	--TempEnchant1/2 and are not in this sequence at all, so adding numWeapon here started
	--the sweep too high and left a stale icon shown whenever a weapon enchant was active.
	local deadIndex = getn(auraTable) + 1
	button = _G[headerName.."AuraButton"..deadIndex]
	while button do
		if button:IsShown() then button:Hide() end
		deadIndex = deadIndex + 1
		button = _G[headerName.."AuraButton"..deadIndex]
	end

	if display >= 1 then
		header:SetWidth(max(right - left, minWidth))
		header:SetHeight(max(top - bottom, minHeight))
	else
		header:SetWidth(minWidth)
		header:SetHeight(minHeight)
	end
end

local freshTable
local releaseTable
do
	local tableReserve = {}
	freshTable = function ()
		local t = next(tableReserve) or {}
		tableReserve[t] = nil
		return t
	end
	releaseTable = function (t)
		tableReserve[t] = wipe(t)
	end
end

local function sortFactory(key, separateOwn, reverse)
	if separateOwn ~= 0 then
		if reverse then
			return function(a, b)
				if a.filter == b.filter then
					local ownA, ownB = a.caster == "player", b.caster == "player"
					if ownA ~= ownB then
						return ownA == (separateOwn > 0)
					end
					return a[key] > b[key]
				else
					return a.filter < b.filter
				end
			end;
		else
			return function(a, b)
				if a.filter == b.filter then
					local ownA, ownB = a.caster == "player", b.caster == "player"
					if ownA ~= ownB then
						return ownA == (separateOwn > 0)
					end
					return a[key] < b[key]
				else
					return a.filter < b.filter
				end
			end;
		end
	else
		if reverse then
			return function(a, b)
				if a.filter == b.filter then
					return a[key] > b[key]
				else
					return a.filter < b.filter
				end
			end;
		else
			return function(a, b)
				if a.filter == b.filter then
					return a[key] < b[key]
				else
					return a.filter < b.filter
				end
			end;
		end
	end
end

local sorters = {}
for _, key in ipairs{"index", "expires"} do
	local label = string.upper(key)
	sorters[label] = {}
	for bool in pairs{[true] = true, [false] = false} do
		sorters[label][bool] = {}
		for sep = -1, 1 do
			sorters[label][bool][sep] = sortFactory(key, sep, bool)
		end
	end
end
sorters.TIME = sorters.EXPIRES

--Blacklist support. Unit frame auras filter through UF:AuraFilter; this module is entirely
--separate and consulted no list at all, so a spell blacklisted off the unit frames carried
--on showing here.
--
--No index-space trap in this one: UpdateHeader already holds the GetPlayerBuff index, and
--SetPlayerBuff takes exactly that, so the name always belongs to the aura being asked
--about. Cached by icon rather than by slot -- these are the player's own auras and the
--texture-to-name mapping does not move. Two different spells sharing an icon would
--collide, which is the same trade the nameplate element makes.
local scanner, scannerLine
local nameByIcon = {}

local function AuraName(buffIndex, icon)
	if nameByIcon[icon] then return nameByIcon[icon] end

	if not scanner then
		scanner = CreateFrame("GameTooltip", "ElvUI_PlayerAuraScanner", nil, "GameTooltipTemplate")
		scannerLine = _G["ElvUI_PlayerAuraScannerTextLeft1"]
	end

	scanner:SetOwner(E.UIParent, "ANCHOR_NONE")
	scanner:ClearLines()
	scanner:SetPlayerBuff(buffIndex)

	local name = scannerLine and scannerLine:GetText()
	if name then nameByIcon[icon] = name end

	return name
end

local function IsBlacklisted(buffIndex, icon)
	local filters = E.global.unitframe.aurafilters
	local spells = filters and filters.Blacklist and filters.Blacklist.spells

	--An empty list means no opinion. Returning here is also what keeps the tooltip scan
	--off this path entirely for anyone who has never blacklisted anything.
	if not (spells and next(spells) ~= nil) then return false end

	local entry = AuraName(buffIndex, icon)
	entry = entry and spells[entry]

	return (entry and entry.enable) and true or false
end

local sortingTable = {}
function A:UpdateHeader(header)
	local filter = header.filter
	local db = self.db.debuffs

	wipe(sortingTable)

	local weaponPosition
	if filter == "HELPFUL" then
		db = self.db.buffs
		weaponPosition = 1
	end

	local i, aura, buffIndex, icon = 0
	while true do
		buffIndex = GetPlayerBuff(i, filter)
		icon = GetPlayerBuffTexture(buffIndex)
		if not icon then break end

		if not IsBlacklisted(buffIndex, icon) then
			aura = freshTable()
			aura.count, aura.dispelType, aura.expires = GetPlayerBuffApplications(buffIndex), GetPlayerBuffDispelType(buffIndex), GetPlayerBuffTimeLeft(buffIndex)
			aura.icon = icon
			aura.index = buffIndex
			aura.filter = filter
			tinsert(sortingTable, aura)
		end

		i = i + 1
	end

	local sortMethod = (sorters[db.sortMethod] or sorters["INDEX"])[db.sortDir == "-"][db.seperateOwn]
	tsort(sortingTable, sortMethod)

	self:ConfigureAuras(header, sortingTable, weaponPosition)
	while sortingTable[1] do
		releaseTable(tremove(sortingTable))
	end
end

--Rebuild one header, or both when given none. The headers only exist while the module is
--enabled, so callers outside it -- the options page, /octoui-filter -- have no business
--knowing that and must not have to nil-check for themselves.
function A:RefreshHeaders(header)
	if header then
		if header.filter then self:UpdateHeader(header) end
		return
	end

	if self.BuffFrame then self:UpdateHeader(self.BuffFrame) end
	if self.DebuffFrame then self:UpdateHeader(self.DebuffFrame) end
end

function A:CreateAuraHeader(filter)
	local name = "ElvUIPlayerDebuffs"
	if filter == "HELPFUL" then
		name = "ElvUIPlayerBuffs"
	end

	local header = CreateFrame("Frame", name, UIParent)
	header:SetClampedToScreen(true)
	header.filter = filter

	header:RegisterEvent("PLAYER_AURAS_CHANGED")
	header:SetScript("OnEvent", function()
		A:UpdateHeader(this)
	end)

	self:UpdateHeader(header)

	return header
end

function A:Initialize()
	if self.db then return end

	if E.private.auras.disableBlizzard then
		E:Kill(BuffFrame)
		E:Kill(TemporaryEnchantFrame)
	end

	if not E.private.auras.enable then return end

	self.db = E.db.auras

	--MMHolder belongs to the Maps module and does not exist at all when the minimap is
	--disabled in the private profile -- Minimap.lua returns before creating it. Anchoring
	--to a nil frame raises, and E:InitializeModules wraps every Initialize in a pcall that
	--drops the error unless the ShowErrors CVar is on, so this module would disappear in
	--complete silence. With disableBlizzard having already killed the stock BuffFrame,
	--that leaves no player buff display at all, and nothing anywhere saying why.
	self.BuffFrame = self:CreateAuraHeader("HELPFUL")
	if MMHolder then
		self.BuffFrame:SetPoint("TOPRIGHT", MMHolder, "TOPLEFT", -(6 + E.Border), -E.Border - E.Spacing)
	else
		self.BuffFrame:SetPoint("TOPRIGHT", E.UIParent, "TOPRIGHT", -(6 + E.Border), -(6 + E.Border))
	end
	E:CreateMover(self.BuffFrame, "BuffsMover", L["Player Buffs"])

	self.BuffFrame.GetUpdateWeaponEnchant = function(self)
		local hasMainHandEnchant, _, _, hasOffHandEnchant = GetWeaponEnchantInfo()
		if hasMainHandEnchant and not self.hasMainHandEnchant then
			self.hasMainHandEnchant = true
			return true
		elseif hasOffHandEnchant and not self.hasOffHandEnchant then
			self.hasOffHandEnchant = true
			return true
		elseif self.hasMainHandEnchant and not hasMainHandEnchant then
			self.hasMainHandEnchant = false
			return true
		elseif self.hasOffHandEnchant and not hasOffHandEnchant then
			self.hasOffHandEnchant = false
			return true
		end
	end

	self.BuffFrame:SetScript("OnUpdate", function()
		if this:GetUpdateWeaponEnchant() then A:UpdateHeader(this) end
	end)

	self.DebuffFrame = self:CreateAuraHeader("HARMFUL")
	if MMHolder then
		self.DebuffFrame:SetPoint("BOTTOMRIGHT", MMHolder, "BOTTOMLEFT", -(6 + E.Border), E.Border + E.Spacing)
	else
		self.DebuffFrame:SetPoint("TOPRIGHT", self.BuffFrame, "BOTTOMRIGHT", 0, -(20 + E.Border))
	end
	E:CreateMover(self.DebuffFrame, "DebuffsMover", L["Player Debuffs"])
end

local function InitializeCallback()
	A:Initialize()
end

E:RegisterModule(A:GetName(), InitializeCallback)