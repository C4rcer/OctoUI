local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local UF = E:GetModule("UnitFrames");
local LSM = LibStub("LibSharedMedia-3.0");

--Cache global variables
--Lua functions
local unpack = unpack
local find, format, lower = string.find, string.format, string.lower
local strsplit = strsplit
local tsort, getn = table.sort, table.getn
local ceil = math.ceil
--WoW API / Variables
local GetTime = GetTime
local CreateFrame = CreateFrame
local IsShiftKeyDown = IsShiftKeyDown
local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local UnitCanAttack = UnitCanAttack
local UnitIsFriend = UnitIsFriend
local UnitIsUnit = UnitIsUnit

function UF:Construct_Buffs(frame)
	local buffs = CreateFrame("Frame", frame:GetName().."Buffs", frame)
	buffs.spacing = E.Spacing
	buffs.PreSetPosition = (not frame:GetScript("OnUpdate")) and self.SortAuras or nil
	buffs.PostCreateIcon = self.Construct_AuraIcon
	buffs.PostUpdateIcon = self.PostUpdateAura
	--buffs.CustomFilter = self.AuraFilter
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
	--debuffs.CustomFilter = self.AuraFilter
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
	button:SetScript("OnClick", function(self)
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
	self.expirationSaved = self.expirationSaved - elapsed
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

function UF:AuraFilter(unit, button, texture, count, dispelType, duration, expiration)
	local db = self:GetParent().db
	if not db or not db[self.type] then return true end

	db = db[self.type]

	if not name then return nil end
	local filterCheck, isUnit, isFriend, isPlayer, canDispell, allowDuration, noDuration, spellPriority

	isPlayer = (caster == "player")
	isFriend = unit and UnitIsFriend("player", unit) and not UnitCanAttack("player", unit)

	button.isPlayer = isPlayer
	button.isFriend = isFriend
	button.isStealable = isStealable
	button.dtype = dispelType
	button.duration = duration
	button.expiration = expiration
	button.name = name
	button.owner = caster --what uses this?
	button.spell = name --what uses this? (SortAurasByName?)
	button.priority = 0

	noDuration = (not duration or duration == 0)
	allowDuration = noDuration or (duration and (duration > 0) and (db.maxDuration == 0 or duration <= db.maxDuration) and (db.minDuration == 0 or duration >= db.minDuration))

	if db.priority ~= "" then
		isUnit = unit and caster and UnitIsUnit(unit, caster)
		canDispell = (self.type == "buffs" and isStealable) or (self.type == "debuffs" and dispelType and E:IsDispellableByMe(dispelType))
		filterCheck, spellPriority = UF:CheckFilter(name, caster, spellID, isFriend, isPlayer, isUnit, allowDuration, noDuration, canDispell, strsplit(",", db.priority))
		if spellPriority then button.priority = spellPriority end -- this is the only difference from auarbars code
	else
		filterCheck = allowDuration and true -- Allow all auras to be shown when the filter list is empty, while obeying duration sliders
	end

	return filterCheck
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