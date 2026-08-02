local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local UF = E:GetModule("UnitFrames");
local LSM = LibStub("LibSharedMedia-3.0");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack
local next, type = next, type
local find, format, lower = string.find, string.format, string.lower
local tsort, getn = table.sort, table.getn
local ceil = math.ceil
--WoW API / Variables
local GetTime = GetTime
local CreateFrame = CreateFrame
local GetPlayerBuff = GetPlayerBuff
local GetPlayerBuffTimeLeft = GetPlayerBuffTimeLeft
local IsShiftKeyDown = IsShiftKeyDown
local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local UnitCanAttack = UnitCanAttack
local UnitIsFriend = UnitIsFriend

function UF:Construct_Buffs(frame)
	local buffs = CreateFrame("Frame", frame:GetName().."Buffs", frame)
	buffs.spacing = E.Spacing
	buffs.PreSetPosition = (not frame:GetScript("OnUpdate")) and self.SortAuras or nil
	buffs.PostCreateIcon = self.Construct_AuraIcon
	buffs.PostUpdateIcon = self.PostUpdateAura
	buffs.CustomFilter = self.AuraFilter
	buffs:SetFrameLevel(frame.RaisedElementParent:GetFrameLevel() + 10) --Make them appear above any text element
	buffs.type = "buffs"
	--Set initial width to prevent division by zero. This value doesn't matter, as it will be updated later
	E:Width(buffs, 100)

	return buffs
end

function UF:Construct_Debuffs(frame)
	local debuffs = CreateFrame("Frame", frame:GetName().."Debuffs", frame)
	debuffs.spacing = E.Spacing
	debuffs.PreSetPosition = (not frame:GetScript("OnUpdate")) and self.SortAuras or nil
	debuffs.PostCreateIcon = self.Construct_AuraIcon
	debuffs.PostUpdateIcon = self.PostUpdateAura
	debuffs.CustomFilter = self.AuraFilter
	debuffs.type = "debuffs"
	debuffs:SetFrameLevel(frame.RaisedElementParent:GetFrameLevel() + 10) --Make them appear above any text element
	--Set initial width to prevent division by zero. This value doesn't matter, as it will be updated later
	E:Width(debuffs, 100)

	return debuffs
end

--Aura text sits on top of spell icon art rather than a flat status bar, so an
--unoutlined font sinks straight into whatever is behind it -- a timer you can only
--half read is no use on a buff you are watching fall off. FontTemplate does give
--unoutlined text a full black shadow, but at one pixel it is not enough against a
--busy icon. Outline this text specifically when the unit frame font has none set; a
--deliberate choice of outline is left exactly as the user made it.
local function AuraFontOutline()
	local outline = E.db.unitframe.fontOutline
	return (not outline or outline == "NONE") and "OUTLINE" or outline
end

--{ text point, icon point, x, y }. ABOVE and BELOW hang the countdown off the icon
--rather than over it, which is the other way to keep it readable -- it costs the gap
--around the icon, so it is a choice rather than the default.
local DURATION_ANCHORS = {
	["CENTER"] = {"CENTER", "CENTER", 1, 1},
	["ABOVE"] = {"BOTTOM", "TOP", 0, 1},
	["BELOW"] = {"TOP", "BOTTOM", 0, -1},
}

local function PositionAuraDuration(text, button)
	local anchor = DURATION_ANCHORS[E.db.unitframe.auraDurationPosition] or DURATION_ANCHORS.CENTER

	text:ClearAllPoints()
	E:Point(text, anchor[1], button, anchor[2], anchor[3], anchor[4])
end

function UF:Construct_AuraIcon(button)
	local offset = UF.thinBorders and E.mult or E.Border

	--A dark strip behind the countdown. The font is outlined already -- the unit frame
	--default is MONOCHROMEOUTLINE -- but an outline only separates glyph from glyph;
	--over bright icon art the whole string still washes out, which no amount of outline
	--fixes. Layers matter here: the icon is ARTWORK and created first in oUF's
	--createAuraIcon, so an ARTWORK texture made now draws above it, and the OVERLAY text
	--below stays above both. Shown and hidden with the text by UpdateAuraTimer, since an
	--empty font string has no rect worth drawing behind.
	button.textBG = button:CreateTexture(nil, "ARTWORK")
	button.textBG:SetTexture(0, 0, 0, 0.65)
	button.textBG:Hide()

	button.text = button:CreateFontString(nil, "OVERLAY")
	PositionAuraDuration(button.text, button)
	button.text:SetJustifyH("CENTER")

	button.textBG:SetPoint("TOPLEFT", button.text, "TOPLEFT", -2, 1)
	button.textBG:SetPoint("BOTTOMRIGHT", button.text, "BOTTOMRIGHT", 2, -1)

	E:SetTemplate(button, "Default", nil, nil, UF.thinBorders, true)

	E:SetInside(button.icon, button, offset, offset)
	button.icon:SetTexCoord(unpack(E.TexCoords))
	button.icon:SetDrawLayer("ARTWORK")

	button.count:ClearAllPoints()
	E:Point(button.count, "BOTTOMRIGHT", 1, 1)
	button.count:SetJustifyH("RIGHT")

	button.overlay:SetTexture(nil)

	button:RegisterForClicks("RightButtonUp")
	--`function(self)` leaves self nil here: a 1.12 script handler is passed nothing and
	--reaches its frame through the `this` global, the way every other handler in this file
	--already does. The modifier check happened to run fine on nil, so this only raised at
	--`self.name` -- i.e. only on the click that was meant to blacklist something.
	button:SetScript("OnClick", function()
		local self = this
		if E.db.unitframe.auraBlacklistModifier == "NONE"
		or not ((E.db.unitframe.auraBlacklistModifier == "SHIFT" and IsShiftKeyDown())
			or (E.db.unitframe.auraBlacklistModifier == "ALT" and IsAltKeyDown())
			or (E.db.unitframe.auraBlacklistModifier == "CTRL" and IsControlKeyDown())) then return end

		local auraName = self.name

		if auraName then
			E:Print(format(L["The spell '%s' has been added to the Blacklist unitframe aura filter."], auraName))
			E.global.unitframe.aurafilters.Blacklist.spells[auraName] = {
				["enable"] = true,
				["priority"] = 0,
			}

			UF:Update_AllFrames()
		end
	end)

	UF:UpdateAuraIconSettings(button, true)
end

function UF:EnableDisable_Auras(frame)
	if frame.db.debuffs.enable or frame.db.buffs.enable then
		if not frame:IsElementEnabled("Aura") then
			frame:EnableElement("Aura")
		end
	else
		if frame:IsElementEnabled("Aura") then
			frame:DisableElement("Aura")
		end
	end
end

local function ReverseUpdate(frame)
	UF:Configure_Auras(frame, "Debuffs")
	UF:Configure_Auras(frame, "Buffs")
end

function UF:Configure_Auras(frame, auraType)
	if not frame.VARIABLES_SET then return end
	local db = frame.db

	local auras = frame[auraType]
	auraType = lower(auraType)
	local rows = db[auraType].numrows

	local totalWidth = frame.UNIT_WIDTH - frame.SPACING*2
	if frame.USE_POWERBAR_OFFSET then
		local powerOffset = ((frame.ORIENTATION == "MIDDLE" and 2 or 1) * frame.POWERBAR_OFFSET)

		if not (db[auraType].attachTo == "POWER" and frame.ORIENTATION == "MIDDLE") then
			totalWidth = totalWidth - powerOffset
		end
	end
	E:Width(auras, totalWidth)

	auras.forceShow = frame.forceShowAuras
	auras.num = db[auraType].perrow * rows
	auras.size = db[auraType].sizeOverride ~= 0 and db[auraType].sizeOverride or ((((auras:GetWidth() - (auras.spacing*(auras.num/rows - 1))) / auras.num)) * rows)

	if db[auraType].sizeOverride and db[auraType].sizeOverride > 0 then
		E:Width(auras, db[auraType].perrow * db[auraType].sizeOverride)
	end

	local attachTo = self:GetAuraAnchorFrame(frame, db[auraType].attachTo, db.debuffs.attachTo == "BUFFS" and db.buffs.attachTo == "DEBUFFS")
	--Use frame.SPACING override since it may be different from E.Spacing due to forced thin borders
	local x, y = E:GetXYOffset(db[auraType].anchorPoint, frame.SPACING)

	if db[auraType].attachTo == "FRAME" then
		y = 0
	elseif db[auraType].attachTo == "HEALTH" or db[auraType].attachTo == "POWER" then
		local newX = E:GetXYOffset(db[auraType].anchorPoint, -frame.BORDER)
		local _, newY = E:GetXYOffset(db[auraType].anchorPoint, (frame.BORDER + frame.SPACING))
		x = newX
		y = newY
	else
		x = 0
	end

	if auraType == "buffs" and frame.Debuffs.attachTo and frame.Debuffs.attachTo == frame.Buffs and db[auraType].attachTo == "DEBUFFS" then
		--Update Debuffs first, as we would otherwise get conflicting anchor points
		--This is usually only an issue on profile change
		ReverseUpdate(frame)
		return
	end

	auras:ClearAllPoints()
	E:Point(auras, E.InversePoints[db[auraType].anchorPoint], attachTo, db[auraType].anchorPoint, x + db[auraType].xOffset, y + db[auraType].yOffset)
	E:Height(auras, auras.size * rows)
	auras["growth-y"] = find(db[auraType].anchorPoint, "TOP") and "UP" or "DOWN"
	auras["growth-x"] = db[auraType].anchorPoint == "LEFT" and "LEFT" or  db[auraType].anchorPoint == "RIGHT" and "RIGHT" or (find(db[auraType].anchorPoint, "LEFT") and "RIGHT" or "LEFT")
	auras.initialAnchor = E.InversePoints[db[auraType].anchorPoint]

	--These are needed for SmartAuraPosition
	auras.attachTo = attachTo
	auras.point = E.InversePoints[db[auraType].anchorPoint]
	auras.anchorPoint = db[auraType].anchorPoint
	auras.xOffset = x + db[auraType].xOffset
	auras.yOffset = y + db[auraType].yOffset

	if db[auraType].enable then
		auras:Show()
		UF:UpdateAuraIconSettings(auras)
	else
		auras:Hide()
	end

	local position = db.smartAuraPosition
	if position == "BUFFS_ON_DEBUFFS" then
		if db.debuffs.attachTo == "BUFFS" then
			E:Print(format(L["This setting caused a conflicting anchor point, where '%s' would be attached to itself. Please check your anchor points. Setting '%s' to be attached to '%s'."], L["Buffs"], L["Debuffs"], L["Frame"]))
			db.debuffs.attachTo = "FRAME"
			frame.Debuffs.attachTo = frame
		end
		frame.Buffs.PostUpdate = nil
		frame.Debuffs.PostUpdate = UF.UpdateBuffsHeaderPosition
	elseif position == "DEBUFFS_ON_BUFFS" then
		if db.buffs.attachTo == "DEBUFFS" then
			E:Print(format(L["This setting caused a conflicting anchor point, where '%s' would be attached to itself. Please check your anchor points. Setting '%s' to be attached to '%s'."], L["Debuffs"], L["Buffs"], L["Frame"]))
			db.buffs.attachTo = "FRAME"
			frame.Buffs.attachTo = frame
		end
		frame.Buffs.PostUpdate = UF.UpdateDebuffsHeaderPosition
		frame.Debuffs.PostUpdate = nil
	elseif position == "FLUID_BUFFS_ON_DEBUFFS" then
		if db.debuffs.attachTo == "BUFFS" then
			E:Print(format(L["This setting caused a conflicting anchor point, where '%s' would be attached to itself. Please check your anchor points. Setting '%s' to be attached to '%s'."], L["Buffs"], L["Debuffs"], L["Frame"]))
			db.debuffs.attachTo = "FRAME"
			frame.Debuffs.attachTo = frame
		end
		frame.Buffs.PostUpdate = UF.UpdateBuffsHeight
		frame.Debuffs.PostUpdate = UF.UpdateBuffsPositionAndDebuffHeight
	elseif position == "FLUID_DEBUFFS_ON_BUFFS" then
		if db.buffs.attachTo == "DEBUFFS" then
			E:Print(format(L["This setting caused a conflicting anchor point, where '%s' would be attached to itself. Please check your anchor points. Setting '%s' to be attached to '%s'."], L["Debuffs"], L["Buffs"], L["Frame"]))
			db.buffs.attachTo = "FRAME"
			frame.Buffs.attachTo = frame
		end
		frame.Buffs.PostUpdate = UF.UpdateDebuffsPositionAndBuffHeight
		frame.Debuffs.PostUpdate = UF.UpdateDebuffsHeight
	else
		frame.Buffs.PostUpdate = nil
		frame.Debuffs.PostUpdate = nil
	end
end

local function SortAurasByTime(a, b)
	if a and b and a:GetParent().db then
		if a:IsShown() and b:IsShown() then
			local sortDirection = a:GetParent().db.sortDirection
			local aTime = a.expiration or -1
			local bTime = b.expiration or -1
			if aTime and bTime then
				if sortDirection == "DESCENDING" then
					return aTime < bTime
				else
					return aTime > bTime
				end
			end
		elseif a:IsShown() then
			return true
		end
	end
end

local function SortAurasByName(a, b)
	if a and b and a:GetParent().db then
		if a:IsShown() and b:IsShown() then
			local sortDirection = a:GetParent().db.sortDirection
			local aName = a.spell or ""
			local bName = b.spell or ""
			if aName and bName then
				if sortDirection == "DESCENDING" then
					return aName < bName
				else
					return aName > bName
				end
			end
		elseif a:IsShown() then
			return true
		end
	end
end

local function SortAurasByDuration(a, b)
	if a and b and a:GetParent().db then
		if a:IsShown() and b:IsShown() then
			local sortDirection = a:GetParent().db.sortDirection
			local aTime = a.duration or -1
			local bTime = b.duration or -1
			if aTime and bTime then
				if sortDirection == "DESCENDING" then
					return aTime < bTime
				else
					return aTime > bTime
				end
			end
		elseif a:IsShown() then
			return true
		end
	end
end

local function SortAurasByCaster(a, b)
	if a and b and a:GetParent().db then
		if a:IsShown() and b:IsShown() then
			local sortDirection = a:GetParent().db.sortDirection
			local aPlayer = a.isPlayer or false
			local bPlayer = b.isPlayer or false
			if sortDirection == "DESCENDING" then
				return (aPlayer and not bPlayer)
			else
				return (not aPlayer and bPlayer)
			end
		elseif a:IsShown() then
			return true
		end
	end
end

function UF:SortAuras()
	--[[if not self.db then return end

	--Sorting by Index is Default
	if self.db.sortMethod == "TIME_REMAINING" then
		tsort(self, SortAurasByTime)
	elseif self.db.sortMethod == "NAME" then
		tsort(self, SortAurasByName)
	elseif self.db.sortMethod == "DURATION" then
		tsort(self, SortAurasByDuration)
	elseif self.db.sortMethod == "PLAYER" then
		tsort(self, SortAurasByCaster)
	end]]

	--Look into possibly applying filter priorities for auras here.

	return 1, getn(self) --from/to range needed for the :SetPosition call in oUF aura element. Without this aura icon position gets all whacky when not sorted by index
end

function UF:UpdateAuraIconSettings(auras, noCycle)
	local frame = auras:GetParent()
	local type = auras.type
	if noCycle then
		frame = auras:GetParent():GetParent()
		type = auras:GetParent().type
	end
	if not frame.db then return end

	local db = frame.db[type]
	local unitframeFont = LSM:Fetch("font", E.db.unitframe.font)
	local unitframeFontOutline = AuraFontOutline()
	local index = 1
	auras.db = db
	if db then
		if not noCycle then
			while auras[index] do
				local button = auras[index]
				PositionAuraDuration(button.text, button)
				E:FontTemplate(button.text, unitframeFont, db.fontSize, unitframeFontOutline)
				E:FontTemplate(button.count, unitframeFont, db.countFontSize or db.fontSize, unitframeFontOutline)

				if db.clickThrough and button:IsMouseEnabled() then
					button:EnableMouse(false)
				elseif not db.clickThrough and not button:IsMouseEnabled() then
					button:EnableMouse(true)
				end
				index = index + 1
			end
		else
			PositionAuraDuration(auras.text, auras)
			E:FontTemplate(auras.text, unitframeFont, db.fontSize, unitframeFontOutline)
			E:FontTemplate(auras.count, unitframeFont, db.countFontSize or db.fontSize, unitframeFontOutline)

			if db.clickThrough and auras:IsMouseEnabled() then
				auras:EnableMouse(false)
			elseif not db.clickThrough and not auras:IsMouseEnabled() then
				auras:EnableMouse(true)
			end
		end
	end
end

function UF:PostUpdateAura(unit, button)
	local auras = button:GetParent()
	local frame = auras:GetParent()
	local type = auras.type
	local db = frame.db and frame.db[type]

	if db then
		if db.clickThrough and button:IsMouseEnabled() then
			button:EnableMouse(false)
		elseif not db.clickThrough and not button:IsMouseEnabled() then
			button:EnableMouse(true)
		end
	end

	if button.isDebuff then
		local color = (button.dtype and DebuffTypeColor[button.dtype]) or DebuffTypeColor.none
		button:SetBackdropBorderColor(color.r * 0.6, color.g * 0.6, color.b * 0.6)
	end

	local size = button:GetParent().size
	if size then
		E:Size(button, size)
	end

	if button.expiration and button.duration and (button.duration ~= 0) then
		local getTime = GetTime()
		if not button:GetScript("OnUpdate") then
			button.expirationTime = button.expiration
			button.expirationSaved = button.expiration - getTime
			button.nextupdate = -1
			--Wrapped, not passed raw: a 1.12 script handler receives no self and no
			--elapsed, only the globals `this` and `arg1`. Handing over the method
			--directly leaves both parameters nil, and the first line of the timer then
			--indexes a nil self on every frame. It only surfaced once the timer
			--actually started being attached at all.
			button:SetScript("OnUpdate", function()
				UF.UpdateAuraTimer(this, arg1 or 0)
			end)
		end
		if (button.expirationTime ~= button.expiration) or (button.expirationSaved ~= (button.expiration - getTime))  then
			button.expirationTime = button.expiration
			button.expirationSaved = button.expiration - getTime
			button.nextupdate = -1
		end
	end

	if button.expiration and button.duration and (button.duration == 0 or button.expiration <= 0) then
		button.expirationTime = nil
		button.expirationSaved = nil
		button:SetScript("OnUpdate", nil)
		if button.text:GetFont() then
			button.text:SetText("")
		end
		if button.textBG then button.textBG:Hide() end
	end
end

function UF:UpdateAuraTimer(elapsed)
	--Re-read rather than count down, for the player. A buff refreshed without the aura set
	--changing fires no event, so PostUpdateAura never runs and the snapshot taken when the
	--buff first appeared is never corrected -- recasting Demon Armor with 20 minutes left
	--went on reading 20 minutes. The standalone panel in Modules/Auras/Auras.lua has always
	--re-read the live value, which is exactly why it was right and this was not.
	--
	--Only the player: no other unit has an API that will quote a remaining time here, and
	--for those the countdown against LibDebuff's reconstructed expiry is all there is.
	if self.playerBuffIndex then
		local timeLeft = GetPlayerBuffTimeLeft(self.playerBuffIndex)
		timeLeft = (timeLeft and timeLeft > 0) and timeLeft or 0

		--Re-reading the live value is only half of it. GetTimeInfo sizes nextupdate for a
		--number that only ever falls -- "no point redrawing until the minute rolls over" --
		--so the throttle below sits on a stale string for up to ~30s at minute scale, and
		--up to ~30 *minutes* once a buff is long enough to read in hours. A refresh puts
		--time back on the aura, which that assumption does not allow for, so recasting
		--Demon Armor at 8 minutes went on reading 8m long enough to look like it was never
		--updating at all. Nothing else will correct it either: a refresh that does not
		--change the aura set fires no event, so PostUpdateAura -- the one place that clears
		--nextupdate -- never runs.
		--
		--Only an increase forces the redraw. A decrease is the normal countdown and is
		--exactly what the throttle exists for; jumping on those would give every aura icon
		--a per-frame SetText. The second of slack keeps float jitter in the client's
		--remaining time from tripping it.
		if timeLeft > (self.expirationSaved or 0) + 1 then
			self.nextupdate = -1
		end

		self.expirationSaved = timeLeft
	else
		self.expirationSaved = self.expirationSaved - elapsed
	end

	if self.nextupdate > 0 then
		self.nextupdate = self.nextupdate - elapsed
		return
	end

	if self.expirationSaved <= 0 then
		self:SetScript("OnUpdate", nil)

		if self.text:GetFont() then
			self.text:SetText("")
		end
		if self.textBG then self.textBG:Hide() end

		return
	end

	local timervalue, formatid
	timervalue, formatid, self.nextupdate = E:GetTimeInfo(self.expirationSaved, 4)

	--E.TimeFormats[formatid][2] is a format spec ("%d", "%.1f"), so the number has to
	--be formatted through it first. Without the inner format the spec itself reached
	--the font string and the timer read "%d" -- SetText takes one string and quietly
	--drops the trailing argument. Core/Cooldowns.lua has always done this correctly.
	local text = format("%s%s|r", E.TimeColors[formatid], format(E.TimeFormats[formatid][2], timervalue))

	if self.text:GetFont() then
		self.text:SetText(text)
	elseif self:GetParent():GetParent().db then
		E:FontTemplate(self.text, LSM:Fetch("font", E.db.unitframe.font), self:GetParent():GetParent().db[self:GetParent().type].fontSize, AuraFontOutline())
		self.text:SetText(text)
	end

	if self.textBG then self.textBG:Show() end
end

--Group frames store these per reaction, single frames store a plain boolean.
local function FilterFlag(value, isFriend)
	if type(value) == "table" then
		return isFriend and value.friendly or value.enemy
	end

	return value
end

--There are two aura index spaces on this client and they do not line up. The player's own
--auras are addressed through GetPlayerBuff/SetPlayerBuff; every other unit is addressed by
--the aura's own index. Reading one with the other returns a different aura's name, which
--is not an error and not visibly wrong -- it just quietly answers about the wrong spell.
--Blacklisting Demon Armor hid Unending Breath that way.
--
--The branching is lifted from UpdateTooltip in Libraries/oUF/elements/auras.lua, which is
--the authority on how this element addresses an aura. NP:ScanAuraName is NOT usable here:
--it only knows the unit-index form.
local scanner, scannerLine
local function ScanAuraName(unit, index, filter)
	if not scanner then
		scanner = CreateFrame("GameTooltip", "ElvUI_UnitFrameAuraScanner", nil, "GameTooltipTemplate")
		scannerLine = _G["ElvUI_UnitFrameAuraScannerTextLeft1"]
	end

	scanner:SetOwner(E.UIParent, "ANCHOR_NONE")
	scanner:ClearLines()

	if unit == "player" then
		local buffIndex = GetPlayerBuff(index - 1, filter)
		if not buffIndex or buffIndex < 0 then return end

		scanner:SetPlayerBuff(buffIndex)
	elseif filter == "HELPFUL" then
		scanner:SetUnitBuff(unit, index, filter)
	else
		scanner:SetUnitDebuff(unit, index, filter)
	end

	return scannerLine and scannerLine:GetText()
end

--A scan is expensive, so the answer is cached against the icon sitting in that slot and
--only redone when it changes -- the same trick the nameplate auras element uses.
local function AuraName(element, unit, index, texture, filter)
	if not index then return end

	if not element.filterNameCache then
		element.filterNameCache, element.filterNameTexture = {}, {}
	end

	if element.filterNameTexture[index] ~= texture then
		element.filterNameTexture[index] = texture
		element.filterNameCache[index] = ScanAuraName(unit, index, filter)
	end

	return element.filterNameCache[index]
end

--Rewritten for what this client will actually part with. Upstream's version read `name`,
--`caster`, `spellID` and `isStealable` -- none of which exist here, UnitAura returns
--texture, count and dispel type -- and then handed them to UF:CheckFilter, which is
--called in exactly one place and defined in none. So it was commented out rather than
--fixed, and with it went `button.dtype`, which is why every debuff border drew in the
--"none" colour.
--
--What is deliberately NOT implemented:
--  * the `priority` token language (Personal, nonPersonal, blockNonPersonal) -- every one
--    of those tokens needs the aura's caster, and there is no caster on this client. No
--    unit frame aura default sets `priority` anyway; the eight that do are nameplates,
--    which run their own filter in Modules/NamePlates/Elements/Auras.lua.
--  * the `noDuration` setting. Debuffs default it to false, meaning "hide auras with no
--    duration", and on this client a duration is only known for debuffs the player
--    applied -- so honouring it would hide most of what is on a party member.
function UF:AuraFilter(unit, button, texture, count, dispelType, duration, expiration)
	local db = self:GetParent().db
	if not db or not db[self.type] then return true end

	db = db[self.type]

	local isFriend = (unit and UnitIsFriend("player", unit) and not UnitCanAttack("player", unit)) and true or false

	--PostUpdateAura reads dtype for the border colour and expiration/duration for the
	--countdown, and the sorters read name.
	button.isFriend = isFriend
	button.dtype = dispelType
	button.duration = duration
	button.expiration = expiration
	button.priority = 0

	--Both default to 0, meaning off, so this only bites for someone who set a slider.
	if duration and duration > 0 then
		if db.maxDuration and db.maxDuration > 0 and duration > db.maxDuration then return false end
		if db.minDuration and db.minDuration > 0 and duration < db.minDuration then return false end
	end

	local useBlacklist = FilterFlag(db.useBlacklist, isFriend)
	local useWhitelist = FilterFlag(db.useWhitelist, isFriend)
	if not (useBlacklist or useWhitelist) then return true end

	local filters = E.global.unitframe.aurafilters
	local blacklist = useBlacklist and filters.Blacklist and filters.Blacklist.spells
	local whitelist = useWhitelist and filters.Whitelist and filters.Whitelist.spells

	--An empty list means "no opinion", never "hide everything" -- buffs ship with
	--useWhitelist on and the Whitelist empty, and treating that as a whitelist proper
	--would hide every buff in the game. It also skips the tooltip scan below, which is
	--the whole cost of this function.
	local haveBlacklist = blacklist and next(blacklist) ~= nil
	local haveWhitelist = whitelist and next(whitelist) ~= nil
	if not (haveBlacklist or haveWhitelist) then return true end

	local name = AuraName(self, unit, button.index, texture, button.filter)
	button.name = name
	button.spell = name

	--No name means no lookup is possible. Show it rather than hide something that cannot
	--defend itself.
	if not name then return true end

	if haveBlacklist then
		local entry = blacklist[name]
		if entry and entry.enable then return false end
	end

	if haveWhitelist then
		local entry = whitelist[name]
		if not (entry and entry.enable) then return false end
	end

	return true
end

function UF:UpdateBuffsHeaderPosition()
	local parent = self:GetParent()
	local buffs = parent.Buffs
	local debuffs = parent.Debuffs
	local numDebuffs = self.visibleDebuffs

	if numDebuffs == 0 then
		buffs:ClearAllPoints()
		E:Point(buffs, debuffs.point, debuffs.attachTo, debuffs.anchorPoint, debuffs.xOffset, debuffs.yOffset)
	else
		buffs:ClearAllPoints()
		E:Point(buffs, buffs.point, buffs.attachTo, buffs.anchorPoint, buffs.xOffset, buffs.yOffset)
	end
end

function UF:UpdateDebuffsHeaderPosition()
	local parent = self:GetParent()
	local debuffs = parent.Debuffs
	local buffs = parent.Buffs
	local numBuffs = self.visibleBuffs

	if numBuffs == 0 then
		debuffs:ClearAllPoints()
		E:Point(debuffs, buffs.point, buffs.attachTo, buffs.anchorPoint, buffs.xOffset, buffs.yOffset)
	else
		debuffs:ClearAllPoints()
		E:Point(debuffs, debuffs.point, debuffs.attachTo, debuffs.anchorPoint, debuffs.xOffset, debuffs.yOffset)
	end
end

function UF:UpdateBuffsPositionAndDebuffHeight()
	local parent = self:GetParent()
	local db = parent.db
	local buffs = parent.Buffs
	local debuffs = parent.Debuffs
	local numDebuffs = self.visibleDebuffs

	if numDebuffs == 0 then
		buffs:ClearAllPoints()
		E:Point(buffs, debuffs.point, debuffs.attachTo, debuffs.anchorPoint, debuffs.xOffset, debuffs.yOffset)
	else
		buffs:ClearAllPoints()
		E:Point(buffs, buffs.point, buffs.attachTo, buffs.anchorPoint, buffs.xOffset, buffs.yOffset)
	end

	if numDebuffs > 0 then
		local numRows = ceil(numDebuffs/db.debuffs.perrow)
		E:Height(debuffs, debuffs.size * (numRows > db.debuffs.numrows and db.debuffs.numrows or numRows))
	else
		E:Height(debuffs, debuffs.size)
	end
end

function UF:UpdateDebuffsPositionAndBuffHeight()
	local parent = self:GetParent()
	local db = parent.db
	local debuffs = parent.Debuffs
	local buffs = parent.Buffs
	local numBuffs = self.visibleBuffs

	if numBuffs == 0 then
		debuffs:ClearAllPoints()
		E:Point(debuffs, buffs.point, buffs.attachTo, buffs.anchorPoint, buffs.xOffset, buffs.yOffset)
	else
		debuffs:ClearAllPoints()
		E:Point(debuffs, debuffs.point, debuffs.attachTo, debuffs.anchorPoint, debuffs.xOffset, debuffs.yOffset)
	end

	if numBuffs > 0 then
		local numRows = ceil(numBuffs/db.buffs.perrow)
		E:Height(buffs, buffs.size * (numRows > db.buffs.numrows and db.buffs.numrows or numRows))
	else
		E:Height(buffs, buffs.size)
	end
end

function UF:UpdateBuffsHeight()
	local parent = self:GetParent()
	local db = parent.db
	local buffs = parent.Buffs
	local numBuffs = self.visibleBuffs

	if numBuffs > 0 then
		local numRows = ceil(numBuffs/db.buffs.perrow)
		E:Height(buffs, buffs.size * (numRows > db.buffs.numrows and db.buffs.numrows or numRows))
	else
		E:Height(buffs, buffs.size)
		-- Any way to get rid of the last row as well?
		-- Using buffs:SetHeight(0) makes frames anchored to this one disappear
	end
end

function UF:UpdateDebuffsHeight()
	local parent = self:GetParent()
	local db = parent.db
	local debuffs = parent.Debuffs
	local numDebuffs = self.visibleDebuffs

	if numDebuffs > 0 then
		local numRows = ceil(numDebuffs/db.debuffs.perrow)
		E:Height(debuffs, debuffs.size * (numRows > db.debuffs.numrows and db.debuffs.numrows or numRows))
	else
		E:Height(debuffs, debuffs.size)
		-- Any way to get rid of the last row as well?
		-- Using debuffs:SetHeight(0) makes frames anchored to this one disappear
	end
end