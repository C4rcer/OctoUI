local E, L, V, P, G = unpack(ElvUI)
local UF = E:NewModule("UnitFrames", "AceTimer-3.0", "AceEvent-3.0", "AceHook-3.0")
local LSM = LibStub("LibSharedMedia-3.0")
UF.LSM = LSM

--Cache global variables
--Lua functions
local _G = _G
local select, pairs, type, unpack, assert, tostring = select, pairs, type, unpack, assert, tostring
local min = math.min
local tremove, tinsert = table.remove, table.insert
local find, gsub, format = string.find, string.gsub, string.format
--WoW API / Variables
local hooksecurefunc = hooksecurefunc
local CreateFrame = CreateFrame
local UnitFrame_OnEnter = UnitFrame_OnEnter
local UnitFrame_OnLeave = UnitFrame_OnLeave
local IsInInstance = IsInInstance
local UnregisterStateDriver = UnregisterStateDriver
local RegisterStateDriver = RegisterStateDriver
local MAX_RAID_MEMBERS = MAX_RAID_MEMBERS

local ns = oUF
ElvUF = ns.oUF
assert(ElvUF, "ElvUI was unable to locate oUF.")

UF.headerstoload = {}
UF.unitgroupstoload = {}
UF.unitstoload = {}

UF.groupPrototype = {}
UF.headerPrototype = {}
UF.headers = {}
UF.groupunits = {}
UF.units = {}

UF.statusbars = {}
UF.fontstrings = {}
UF.badHeaderPoints = {
	["TOP"] = "BOTTOM",
	["LEFT"] = "RIGHT",
	["BOTTOM"] = "TOP",
	["RIGHT"] = "LEFT"
}

UF.headerFunctions = {}

UF.classMaxResourceBar = {
	["DRUID"] = 1
}

UF.mapIDs = {
	[443] = 10, -- Warsong Gulch
	[461] = 15, -- Arathi Basin
	[401] = 40, -- Alterac Valley
	[566] = 15, -- Eye of the Storm
}

UF.headerGroupBy = {
	["CLASS"] = function(header)
		header:SetAttribute("groupingOrder", "DRUID,HUNTER,MAGE,PALADIN,PRIEST,SHAMAN,WARLOCK,WARRIOR")
		header:SetAttribute("sortMethod", "NAME")
		header:SetAttribute("groupBy", "CLASS")
	end,
	["NAME"] = function(header)
		header:SetAttribute("groupingOrder", "1,2,3,4,5,6,7,8")
		header:SetAttribute("sortMethod", "NAME")
		header:SetAttribute("groupBy", nil)
	end,
	["GROUP"] = function(header)
		header:SetAttribute("groupingOrder", "1,2,3,4,5,6,7,8")
		header:SetAttribute("sortMethod", "INDEX")
		header:SetAttribute("groupBy", "GROUP")
	end,
	["PETNAME"] = function(header)
		header:SetAttribute("groupingOrder", "1,2,3,4,5,6,7,8")
		header:SetAttribute("sortMethod", "NAME")
		header:SetAttribute("groupBy", nil)
		header:SetAttribute("filterOnPet", true)  --This is the line that matters. Without this, it sorts based on the owners name
	end,
}

local POINT_COLUMN_ANCHOR_TO_DIRECTION = {
	["TOPTOP"] = "UP_RIGHT",
	["BOTTOMBOTTOM"] = "TOP_RIGHT",
	["LEFTLEFT"] = "RIGHT_UP",
	["RIGHTRIGHT"] = "LEFT_UP",
	["RIGHTTOP"] = "LEFT_DOWN",
	["LEFTTOP"] = "RIGHT_DOWN",
	["LEFTBOTTOM"] = "RIGHT_UP",
	["RIGHTBOTTOM"] = "LEFT_UP",
	["BOTTOMRIGHT"] = "UP_LEFT",
	["BOTTOMLEFT"] = "UP_RIGHT",
	["TOPRIGHT"] = "DOWN_LEFT",
	["TOPLEFT"] = "DOWN_RIGHT"
}

local DIRECTION_TO_POINT = {
	DOWN_RIGHT = "TOP",
	DOWN_LEFT = "TOP",
	UP_RIGHT = "BOTTOM",
	UP_LEFT = "BOTTOM",
	RIGHT_DOWN = "LEFT",
	RIGHT_UP = "LEFT",
	LEFT_DOWN = "RIGHT",
	LEFT_UP = "RIGHT",
	UP = "BOTTOM",
	DOWN = "TOP"
}

local DIRECTION_TO_GROUP_ANCHOR_POINT = {
	DOWN_RIGHT = "TOPLEFT",
	DOWN_LEFT = "TOPRIGHT",
	UP_RIGHT = "BOTTOMLEFT",
	UP_LEFT = "BOTTOMRIGHT",
	RIGHT_DOWN = "TOPLEFT",
	RIGHT_UP = "BOTTOMLEFT",
	LEFT_DOWN = "TOPRIGHT",
	LEFT_UP = "BOTTOMRIGHT",
	OUT_RIGHT_UP = "BOTTOM",
	OUT_LEFT_UP = "BOTTOM",
	OUT_RIGHT_DOWN = "TOP",
	OUT_LEFT_DOWN = "TOP",
	OUT_UP_RIGHT = "LEFT",
	OUT_UP_LEFT = "RIGHT",
	OUT_DOWN_RIGHT = "LEFT",
	OUT_DOWN_LEFT = "RIGHT"
}

local INVERTED_DIRECTION_TO_COLUMN_ANCHOR_POINT = {
	DOWN_RIGHT = "RIGHT",
	DOWN_LEFT = "LEFT",
	UP_RIGHT = "RIGHT",
	UP_LEFT = "LEFT",
	RIGHT_DOWN = "BOTTOM",
	RIGHT_UP = "TOP",
	LEFT_DOWN = "BOTTOM",
	LEFT_UP = "TOP",
	UP = "TOP",
	DOWN = "BOTTOM"
}

local DIRECTION_TO_COLUMN_ANCHOR_POINT = {
	DOWN_RIGHT = "LEFT",
	DOWN_LEFT = "RIGHT",
	UP_RIGHT = "LEFT",
	UP_LEFT = "RIGHT",
	RIGHT_DOWN = "TOP",
	RIGHT_UP = "BOTTOM",
	LEFT_DOWN = "TOP",
	LEFT_UP = "BOTTOM"
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

function UF:ConvertGroupDB(group)
	local db = self.db.units[group.groupName]
	if db.point and db.columnAnchorPoint then
		db.growthDirection = POINT_COLUMN_ANCHOR_TO_DIRECTION[db.point..db.columnAnchorPoint];
		db.point = nil;
		db.columnAnchorPoint = nil;
	end

	if db.growthDirection == "UP" then
		db.growthDirection = "UP_RIGHT"
	end

	if db.growthDirection == "DOWN" then
		db.growthDirection = "DOWN_RIGHT"
	end
end

function UF:Construct_UF(frame, unit)
	frame:SetFrameStrata("LOW")
	frame:SetScript("OnEnter", UnitFrame_OnEnter)
	frame:SetScript("OnLeave", UnitFrame_OnLeave)

	if(self.thinBorders) then
		frame.SPACING = 0
		frame.BORDER = E.mult
	else
		frame.BORDER = E.Border
		frame.SPACING = E.Spacing
	end

	frame.SHADOW_SPACING = 3
	frame.HAPPINESS_WIDTH = 0
	frame.CLASSBAR_YOFFSET = 0	--placeholder
	frame.BOTTOM_OFFSET = 0 --placeholder

	frame.RaisedElementParent = CreateFrame("Frame", nil, frame)
	frame.RaisedElementParent:SetFrameLevel(frame:GetFrameLevel() + 100)
	frame.RaisedElementParent.TextureParent = CreateFrame("Frame", nil, frame.RaisedElementParent)
	frame.RaisedElementParent.TextureParent:SetFrameLevel(frame.RaisedElementParent:GetFrameLevel() + 1)

	local stringTitle = E:StringTitle(unit)
	if string.find(stringTitle, "target") then
		stringTitle = gsub(stringTitle, "target", "Target")
	end
	self["Construct_"..stringTitle.."Frame"](self, frame, unit)

	self:Update_StatusBars()
	self:Update_FontStrings()
	return frame
end

function UF:GetObjectAnchorPoint(frame, point)
	if not frame[point] or point == "Frame" then
		return frame
	elseif frame[point] and not frame[point]:IsShown() then
		return frame.Health
	else
		return frame[point]
	end
end

function UF:GetPositionOffset(position, offset)
	if not offset then offset = 2; end
	local x, y = 0, 0
	if find(position, "LEFT") then
		x = offset
	elseif find(position, "RIGHT") then
		x = -offset
	end

	if find(position, "TOP") then
		y = -offset
	elseif find(position, "BOTTOM") then
		y = offset
	end

	return x, y
end

function UF:GetAuraOffset(p1, p2)
	local x, y = 0, 0
	if p1 == "RIGHT" and p2 == "LEFT" then
		x = -3
	elseif p1 == "LEFT" and p2 == "RIGHT" then
		x = 3
	end

	if find(p1, "TOP") and find(p2, "BOTTOM") then
		y = -1
	elseif find(p1, "BOTTOM") and find(p2, "TOP") then
		y = 1
	end

	return E:Scale(x), E:Scale(y)
end

function UF:GetAuraAnchorFrame(frame, attachTo, isConflict)
	if isConflict then
		E:Print(format(L["%s frame(s) has a conflicting anchor point, please change either the buff or debuff anchor point so they are not attached to each other. Forcing the debuffs to be attached to the main unitframe until fixed."], E:StringTitle(frame:GetName())))
	end

	if isConflict or attachTo == "FRAME" then
		return frame
	elseif attachTo == "BUFFS" then
		return frame.Buffs
	elseif attachTo == "DEBUFFS" then
		return frame.Debuffs
	elseif attachTo == "HEALTH" then
		return frame.Health
	elseif attachTo == "POWER" and frame.Power then
		return frame.Power
	else
		return frame
	end
end

function UF:UpdateColors()
	local db = self.db.colors

	local good = E:GetColorTable(db.reaction.GOOD)
	local bad = E:GetColorTable(db.reaction.BAD)
	local neutral = E:GetColorTable(db.reaction.NEUTRAL)

	ElvUF.colors.tapped = E:GetColorTable(db.tapped);
	ElvUF.colors.disconnected = E:GetColorTable(db.disconnected);
	ElvUF.colors.health = E:GetColorTable(db.health);
	ElvUF.colors.power[0] = E:GetColorTable(db.power.MANA);
	ElvUF.colors.power[1] = E:GetColorTable(db.power.RAGE);
	ElvUF.colors.power[2] = E:GetColorTable(db.power.FOCUS);
	ElvUF.colors.power[3] = E:GetColorTable(db.power.ENERGY);

	ElvUF.colors.ComboPoints = {}
	ElvUF.colors.ComboPoints[1] = E:GetColorTable(db.classResources.comboPoints[1])
	ElvUF.colors.ComboPoints[2] = E:GetColorTable(db.classResources.comboPoints[2])
	ElvUF.colors.ComboPoints[3] = E:GetColorTable(db.classResources.comboPoints[3])
	ElvUF.colors.ComboPoints[4] = E:GetColorTable(db.classResources.comboPoints[4])
	ElvUF.colors.ComboPoints[5] = E:GetColorTable(db.classResources.comboPoints[5])

	ElvUF.colors.reaction[1] = bad
	ElvUF.colors.reaction[2] = bad
	ElvUF.colors.reaction[3] = bad
	ElvUF.colors.reaction[4] = neutral
	ElvUF.colors.reaction[5] = good
	ElvUF.colors.reaction[6] = good
	ElvUF.colors.reaction[7] = good
	ElvUF.colors.reaction[8] = good
	ElvUF.colors.smooth = {1, 0, 0,
	1, 1, 0,
	unpack(E:GetColorTable(db.health))}

	ElvUF.colors.castColor = E:GetColorTable(db.castColor);
end

function UF:Update_StatusBars()
	local statusBarTexture = LSM:Fetch("statusbar", self.db.statusbar)
	for statusbar in pairs(UF.statusbars) do
		if statusbar and statusbar:GetObjectType() == "StatusBar" and not statusbar.isTransparent then
			statusbar:SetStatusBarTexture(statusBarTexture)
		elseif statusbar and statusbar:GetObjectType() == "Texture" then
			statusbar:SetTexture(statusBarTexture)
		end
	end
end

function UF:Update_StatusBar(bar)
	bar:SetStatusBarTexture(LSM:Fetch("statusbar", self.db.statusbar))
end

function UF:Update_FontString(object)
	E:FontTemplate(object, LSM:Fetch("font", self.db.font), self.db.fontSize, self.db.fontOutline)
end

function UF:Update_FontStrings()
	local stringFont = LSM:Fetch("font", self.db.font)
	for font in pairs(UF.fontstrings) do
		E:FontTemplate(font, stringFont, self.db.fontSize, self.db.fontOutline)
	end
end

function UF:Configure_FontString(obj)
	UF.fontstrings[obj] = true
	E:FontTemplate(obj) --This is temporary.
end

function UF:Update_AllFrames()
	if E.private.unitframe.enable ~= true then return; end
	self:UpdateColors()
	self:Update_FontStrings()
	self:Update_StatusBars()

	for unit in pairs(self.units) do
		if self.db.units[unit].enable then
			self[unit]:Enable()
			self[unit]:Update()
			E:EnableMover(self[unit].mover:GetName())
		else
			self[unit]:Disable()
			E:DisableMover(self[unit].mover:GetName())
		end
	end

	self:UpdateAllHeaders()
end

function UF:HeaderUpdateSpecificElement(group, elementName)
	assert(self[group], "Invalid group specified.")
	for i = 1, self[group]:GetNumChildren() do
		local frame = select(i, self[group]:GetChildren())
		if frame and frame.Health then
			frame:UpdateElement(elementName)
		end
	end
end

--Keep an eye on this one, it may need to be changed too
--Reference: http://www.tukui.org/forums/topic.php?id=35332
function UF.groupPrototype:GetAttribute(name)
	return self.groups[1]:GetAttribute(name)
end

function UF.groupPrototype:Configure_Groups(self)
	local db = UF.db.units[self.groupName]

	local point
	local width, height, newCols, newRows = 0, 0, 0, 0
	local direction = db.growthDirection
	local xMult, yMult = DIRECTION_TO_HORIZONTAL_SPACING_MULTIPLIER[direction], DIRECTION_TO_VERTICAL_SPACING_MULTIPLIER[direction]
	local UNIT_HEIGHT = db.infoPanel and db.infoPanel.enable and (db.height + db.infoPanel.height) or db.height

	local numGroups = self.numGroups
	for i = 1, numGroups do
		local group = self.groups[i]

		point = DIRECTION_TO_POINT[direction]

		if group then
			UF:ConvertGroupDB(group)
			if point == "LEFT" or point == "RIGHT" then
				group:SetAttribute("xOffset", db.horizontalSpacing * DIRECTION_TO_HORIZONTAL_SPACING_MULTIPLIER[direction])
				group:SetAttribute("yOffset", 0)
				group:SetAttribute("columnSpacing", db.verticalSpacing)
			else
				group:SetAttribute("xOffset", 0)
				group:SetAttribute("yOffset", db.verticalSpacing * DIRECTION_TO_VERTICAL_SPACING_MULTIPLIER[direction])
				group:SetAttribute("columnSpacing", db.horizontalSpacing)
			end

			--[[if not group.isForced then
				if not group.initialized then
					group:SetAttribute("startingIndex", db.raidWideSorting and (-min(numGroups * (db.groupsPerRowCol * 5), MAX_RAID_MEMBERS) + 1) or -4)
					group:Show()
					group.initialized = true
				end
				group:SetAttribute("startingIndex", 1)
			end]]

			group:ClearAllPoints()
			if db.raidWideSorting and db.invertGroupingOrder then
				group:SetAttribute("columnAnchorPoint", INVERTED_DIRECTION_TO_COLUMN_ANCHOR_POINT[direction])
			else
				group:SetAttribute("columnAnchorPoint", DIRECTION_TO_COLUMN_ANCHOR_POINT[direction])
			end

			group:ClearChildPoints()
			group:SetAttribute("point", point)

			if not group.isForced then
				group:SetAttribute("maxColumns", db.raidWideSorting and numGroups or 1)
				group:SetAttribute("unitsPerColumn", db.raidWideSorting and (db.groupsPerRowCol * 5) or 5)
				UF.headerGroupBy[db.groupBy](group)
				group:SetAttribute("sortDir", db.sortDir)
				group:SetAttribute("showPlayer", db.showPlayer)
			end

			if i == 1 and db.raidWideSorting then
				group:SetAttribute("groupFilter", "1,2,3,4,5,6,7,8")
			else
				group:SetAttribute("groupFilter", tostring(i))
			end
		end

		--MATH!! WOOT
		point = DIRECTION_TO_GROUP_ANCHOR_POINT[direction]
		if db.raidWideSorting and db.startFromCenter then
			point = DIRECTION_TO_GROUP_ANCHOR_POINT["OUT_"..direction]
		end
		if math.mod(i - 1, db.groupsPerRowCol) == 0 then
			if DIRECTION_TO_POINT[direction] == "LEFT" or DIRECTION_TO_POINT[direction] == "RIGHT" then
				if group then
					E:Point(group, point, self, point, 0, height * yMult)
				end
				height = height + UNIT_HEIGHT + db.verticalSpacing
				newRows = newRows + 1
			else
				if group then
					E:Point(group, point, self, point, width * xMult, 0)
				end
				width = width + db.width + db.horizontalSpacing

				newCols = newCols + 1
			end
		else
			if DIRECTION_TO_POINT[direction] == "LEFT" or DIRECTION_TO_POINT[direction] == "RIGHT" then
				if newRows == 1 then
					if group then
						E:Point(group, point, self, point, width * xMult, 0)
					end
					width = width + ((db.width + db.horizontalSpacing) * 5)
					newCols = newCols + 1
				elseif group then
					E:Point(group, point, self, point, (((db.width + db.horizontalSpacing) * 5) * (math.mod(i-1, db.groupsPerRowCol))) * xMult, ((UNIT_HEIGHT + db.verticalSpacing) * (newRows - 1)) * yMult)
				end
			else
				if newCols == 1 then
					if group then
						E:Point(group, point, self, point, 0, height * yMult)
					end
					height = height + ((UNIT_HEIGHT + db.verticalSpacing) * 5)
					newRows = newRows + 1
				elseif group then
					E:Point(group, point, self, point, ((db.width + db.horizontalSpacing) * (newCols - 1)) * xMult, (((UNIT_HEIGHT + db.verticalSpacing) * 5) * (math.mod(i-1, db.groupsPerRowCol))) * yMult)
				end
			end
		end

		if height == 0 then
			height = height + ((UNIT_HEIGHT + db.verticalSpacing) * 5)
		elseif width == 0 then
			width = width + ((db.width + db.horizontalSpacing) * 5)
		end
	end

	if not self.isInstanceForced then
		self.dirtyWidth = width - db.horizontalSpacing
		self.dirtyHeight = height - db.verticalSpacing
	end

	if self.mover then
		self.mover.positionOverride = DIRECTION_TO_GROUP_ANCHOR_POINT[direction]
		E:UpdatePositionOverride(self.mover:GetName())
		self:GetScript("OnSizeChanged")(self) --Mover size is not updated if frame is hidden, so call an update manually
	end

	E:Size(self, width - db.horizontalSpacing, height - db.verticalSpacing)
end

function UF.groupPrototype:Update(self)
	local group = self.groupName

	UF[group].db = UF.db.units[group]
	for i = 1, getn(self.groups) do
		self.groups[i].db = UF.db.units[group]
		self.groups[i]:Update()
	end
end

--[[
	WHICH GROUP HEADER SHOULD BE ON SCREEN.

	The profile carries a `visibility` string per header -- things like
	"[target=raid26,exists] hide;show" -- which are RETAIL MACRO CONDITIONALS fed
	to RegisterStateDriver. That API does not exist on 1.12, so every call to it
	in this file is commented out, and the strings have been inert data ever
	since. Visibility therefore came down to `db.enable` alone, and since raid,
	raid40 and party are all enabled by default, ALL THREE HEADERS SHOWED AT
	ONCE. In a raid that draws every player twice, once from the raid header and
	once from raid40, overlapping -- reported 2026-08-22 with a screenshot of
	exactly that.

	So evaluate the same rule natively. The three shipped strings say:

	  party   hide when raid6 exists, or when ungrouped   -> show for 1-5
	  raid    hide when raid6 missing or raid26 exists    -> show for 6-25
	  raid40  hide when raid26 missing                    -> show for 26+

	"raid6 exists" is simply "the raid has at least six members", which
	GetNumRaidMembers answers directly. A raid of fewer than six falls to the
	party header, which is what the party string's second clause is for and what
	happens when a party is converted without gaining anyone.
]]
function UF:HeaderShouldShow(group)
	local raid = GetNumRaidMembers() or 0
	local party = GetNumPartyMembers() or 0

	if group == "raid40" then
		return raid >= 26
	elseif group == "raid" then
		return raid >= 6 and raid < 26
	elseif group == "party" then
		--A raid under six has no raid header showing, so the party frames are
		--the ones that must cover it.
		if raid > 0 then return raid < 6 end
		return party > 0
	end

	--Anything else keeps the old behaviour: enabled means shown.
	return true
end

--Re-applies the rule above to all three group headers. Kept separate from
--UpdateHeader so a roster change costs a Show/Hide rather than a full rebuild.
--
--Run TWICE, for the reason RebuildGroupHeaders already documents: the roster
--events arrive before the client can answer for the new member, so a count read
--now can be one short. The second pass changes nothing when the first was right.
--[[
	HIDING IT IS NOT ENOUGH, and reacting faster does not help.

	Hiding the wrong header worked and then did not stay worked: something calls
	Show on it again and the overlap comes back at random. Chasing the caller is
	a race that has to be won every time, and losing it once puts every raid
	member on screen twice.

	So the header is GAGGED rather than merely hidden: while it should not be
	visible its Show method is replaced with a no-op, which is the same technique
	Modules\Maps\MinimapButtons.lua uses on SetPoint for collected buttons that
	re-anchor themselves. Whatever calls Show, and however often, it stays down.

	The gag is always lifted at the top of this function before anything is
	decided, so a roster change, a config preview or /moveui can bring the header
	back the moment the rule says it should be up. Nothing here is one-way.
]]
function UF:UpdateHeaderVisibility()
	local groups = {"party", "raid", "raid40"}

	for i = 1, getn(groups) do
		local group = groups[i]
		local header = self[group]
		local db = self.db and self.db.units and self.db.units[group]

		if header and db and db.enable then
			--Ungag first, unconditionally: the decision below has to be free to go
			--either way, and a header left gagged could never be shown again.
			if header.octoRealShow then
				header.Show = header.octoRealShow
				header.octoRealShow = nil
			end

			--The config preview deliberately shows a header with no group to
			--match, and outranks the roster.
			if header.isForced or header.blockVisibilityChanges then
				--left exactly as the preview put it
			elseif UF:HeaderShouldShow(group) then
				header:Show()
			else
				header:Hide()
				header.octoRealShow = header.Show
				header.Show = E.noop
			end
		end
	end
end

--Its own constant, NOT the REBUILD_RETRY further down this file. A local declared
--after the function that reads it resolves to a global and is nil at runtime --
--the trap RebuildGroupHeaders' own comments warn about, and one I walked into
--writing this.
local VISIBILITY_RETRY = 0.5

--[[
	DEBOUNCED, AND DELIBERATELY NOT IMMEDIATE.

	The first version evaluated now AND again half a second later, copying
	RebuildGroupHeaders' twice-over pattern. That was wrong here, and reported as
	the raid frames "flickering between normal and overlap".

	RebuildGroupHeaders can afford the early pass because rebuilding twice is
	harmless -- the second run re-sorts what the first already placed. This is a
	SHOW OR HIDE, and the early pass reads a roster the client cannot answer for
	yet. One member short is enough to cross 5/6 or 25/26, so the immediate call
	shows the wrong header and the delayed one takes it away again: a visible
	half-second of the overlap, caused by the fix for the overlap.

	A roster change also arrives as a burst of events, so each is cancelled by
	the next and only the settled state is ever acted on.
]]
function UF:RAID_ROSTER_UPDATE()
	if self.visibilityTimer then
		self:CancelTimer(self.visibilityTimer, true)
	end

	self.visibilityTimer = self:ScheduleTimer("UpdateHeaderVisibility", VISIBILITY_RETRY)
end

UF.PARTY_MEMBERS_CHANGED = UF.RAID_ROSTER_UPDATE

function UF.groupPrototype:AdjustVisibility(self)
	if not self.isForced then
		local numGroups = self.numGroups
		for i = 1, getn(self.groups) do
			local group = self.groups[i]
			if (i <= numGroups) and ((self.db.raidWideSorting and i <= 1) or not self.db.raidWideSorting) then
				group:Show()
			else
				if group.forceShow then
					group:Hide()
					UF:UnshowChildUnits(group, group:GetChildren())
					group:SetAttribute("startingIndex", 1)
				else
					group:Reset()
				end
			end
		end
	end
end

function UF.groupPrototype:UpdateHeader(self)
	local group = self.groupName;
	UF["Update_"..E:StringTitle(group).."Header"](UF, self, UF.db.units[group]);
end

--Rebuild the child roster of a group container's headers.
--
--The unit buttons are built by oUF's SecureGroupHeader_Update, and the only thing that
--calls it on a roster change is the header's own OnEvent from Libraries\oUF\templates.xml.
--That handler is right and does fire -- but PARTY_MEMBERS_CHANGED arrives before the new
--member's unit data does, so the UnitExists("partyN") inside GetGroupRosterInfo is still
--false and that member is filtered out of the sort it drives. Nothing fires afterwards to
--correct it, which is why a member who joined never got a frame until something else
--rebuilt the header -- and the thing that did was /reload, through the template's OnShow.
--
--Hence twice: once now, which is right for a member leaving and for anything the client
--already knows, and once shortly after, by which time it does. A rebuild re-sorts and
--re-anchors what is already there, so the second pass changes nothing when the first
--already got it right.
local REBUILD_RETRY = 0.5

function UF:RebuildGroupHeaders(container)
	if not container then return end

	--A container with numGroups holds the real headers in .groups; without one it *is* the
	--header. GetAttribute tells them apart: only a SpawnHeader frame has it.
	local headers = container.groups or (container.GetAttribute and {container})
	if not headers then return end

	for i = 1, getn(headers) do
		local header = headers[i]
		--IsVisible rather than IsShown, matching the check the template's own handler
		--makes: building buttons into a header whose container is hidden is work for
		--something nobody can see, and it will be rebuilt when it is shown again.
		if header and header.GetAttribute and header:IsVisible() then
			SecureGroupHeader_Update(header)
		end
	end
end

function UF:ScheduleGroupHeaderRebuild(container)
	UF:RebuildGroupHeaders(container)
	E:Delay(REBUILD_RETRY, UF.RebuildGroupHeaders, UF, container)
end

function UF.headerPrototype:ClearChildPoints()
	for i = 1, self:GetNumChildren() do
		local child = select(i, self:GetChildren())
		child:ClearAllPoints()
	end
end

function UF.headerPrototype:Update(isForced)
	local group = self.groupName
	local db = UF.db.units[group]

	local i = 1
	local child = self:GetAttribute("child" .. i)

	while child do
		UF["Update_"..E:StringTitle(group).."Frames"](UF, child, db)

		if _G[child:GetName().."Pet"] then
			UF["Update_"..E:StringTitle(group).."Frames"](UF, _G[child:GetName().."Pet"], db)
		end

		if _G[child:GetName().."Target"] then
			UF["Update_"..E:StringTitle(group).."Frames"](UF, _G[child:GetName().."Target"], db)
		end

		i = i + 1
		child = self:GetAttribute("child" .. i)
	end
end

function UF.headerPrototype:Reset()
	self:Hide()

	self:SetAttribute("showPlayer", true)

	self:SetAttribute("showSolo", true)
	self:SetAttribute("showParty", true)
	self:SetAttribute("showRaid", true)

	self:SetAttribute("columnSpacing", nil)
	self:SetAttribute("columnAnchorPoint", nil)
	self:SetAttribute("groupBy", nil)
	self:SetAttribute("groupFilter", nil)
	self:SetAttribute("groupingOrder", nil)
	self:SetAttribute("maxColumns", nil)
	self:SetAttribute("nameList", nil)
	self:SetAttribute("point", nil)
	self:SetAttribute("sortDir", nil)
	self:SetAttribute("sortMethod", "NAME")
	self:SetAttribute("startingIndex", nil)
	self:SetAttribute("strictFiltering", nil)
	self:SetAttribute("unitsPerColumn", nil)
	self:SetAttribute("xOffset", nil)
	self:SetAttribute("yOffset", nil)
end

function UF:CreateHeader(parent, groupFilter, overrideName, template, groupName, headerTemplate)
	local group = parent.groupName or groupName
	local db = UF.db.units[group]
	ElvUF:SetActiveStyle("ElvUF_"..E:StringTitle(group))
	local header = ElvUF:SpawnHeader(overrideName, headerTemplate, nil,
			"groupFilter", groupFilter,
			"showParty", true,
			"showRaid", true,
			"showSolo", false,
			template and "template", template)

	header.groupName = group
	header:SetParent(parent)
	header:Show()

	for k, v in pairs(self.headerPrototype) do
		header[k] = v
	end

	return header
end

function UF:CreateAndUpdateHeaderGroup(group, groupFilter, template, headerUpdate, headerTemplate)
	local db = self.db.units[group]
	local numGroups = db.numGroups

	if not self[group] then
		local stringTitle = E:StringTitle(group)
		ElvUF:RegisterStyle("ElvUF_"..stringTitle, UF["Construct_"..stringTitle.."Frames"])
		ElvUF:SetActiveStyle("ElvUF_"..stringTitle)

		if db.numGroups then
			self[group] = CreateFrame("Frame", "ElvUF_"..stringTitle, E.UIParent)
			self[group]:SetFrameStrata("LOW")
			self[group].groups = {}
			self[group].groupName = group
			self[group].template = self[group].template or template
			self[group].headerTemplate = self[group].headerTemplate or headerTemplate
			if not UF.headerFunctions[group] then UF.headerFunctions[group] = {} end
			for k, v in pairs(self.groupPrototype) do
				UF.headerFunctions[group][k] = v
			end
		else
			self[group] = self:CreateHeader(E.UIParent, groupFilter, "ElvUF_"..E:StringTitle(group), template, group, headerTemplate)
		end

		self[group].db = db
		self.headers[group] = self[group]
		self[group]:Show()
	end

	self[group].numGroups = numGroups
	if numGroups then
		if db.raidWideSorting then
			if not self[group].groups[1] then
				self[group].groups[1] = self:CreateHeader(self[group], nil, "ElvUF_"..E:StringTitle(self[group].groupName).."Group1", template or self[group].template, nil, headerTemplate or self[group].headerTemplate)
			end
		else
			while numGroups > getn(self[group].groups) do
				local index = tostring(getn(self[group].groups) + 1)
				tinsert(self[group].groups, self:CreateHeader(self[group], index, "ElvUF_"..E:StringTitle(self[group].groupName).."Group"..index, template or self[group].template, nil, headerTemplate or self[group].headerTemplate))
			end
		end

		UF.headerFunctions[group]:AdjustVisibility(self[group])

		if headerUpdate or not self[group].mover then
			UF.headerFunctions[group]:Configure_Groups(self[group])
			if not self[group].isForced and not self[group].blockVisibilityChanges then
			--	RegisterStateDriver(self[group], "visibility", db.visibility)
			end
		else
			UF.headerFunctions[group]:Configure_Groups(self[group])
			UF.headerFunctions[group]:UpdateHeader(self[group])
			UF.headerFunctions[group]:Update(self[group])
		end

		if db.enable then
			--isForced is the config preview, which deliberately shows a header with
			--no group to match. It must outrank the roster.
			if self[group].isForced or self[group].blockVisibilityChanges
				or UF:HeaderShouldShow(group) then
				self[group]:Show()
			else
				self[group]:Hide()
			end

			if self[group].mover then
				E:EnableMover(self[group].mover:GetName())
			end
		else
			--UnregisterStateDriver(self[group], "visibility")
			self[group]:Hide()
			if self[group].mover then
				E:DisableMover(self[group].mover:GetName())
			end
			return
		end
	else
		self[group].db = db

		if not UF.headerFunctions[group] then UF.headerFunctions[group] = {} end
		UF.headerFunctions[group]["Update"] = function()
			local db = UF.db.units[group]
			if db.enable ~= true then
				--UnregisterStateDriver(UF[group], "visibility")
				UF[group]:Hide()
				if(UF[group].mover) then
					E:DisableMover(UF[group].mover:GetName())
				end
				return
			end
			UF["Update_"..E:StringTitle(group).."Header"](UF, UF[group], db)

			for i = 1, UF[group]:GetNumChildren() do
				local child = select(i, UF[group]:GetChildren())
				UF["Update_"..E:StringTitle(group).."Frames"](UF, child, UF.db.units[group])

				if _G[child:GetName().."Target"] then
					UF["Update_"..E:StringTitle(group).."Frames"](UF, _G[child:GetName().."Target"], UF.db.units[group])
				end

				if _G[child:GetName().."Pet"] then
					UF["Update_"..E:StringTitle(group).."Frames"](UF, _G[child:GetName().."Pet"], UF.db.units[group])
				end
			end

			E:EnableMover(UF[group].mover:GetName())
		end

		if headerUpdate then
			UF["Update_"..E:StringTitle(group).."Header"](self, self[group], db)
		else
			UF.headerFunctions[group]:Update(self[group])
		end
	end
end

function UF:PLAYER_REGEN_ENABLED()
	self:Update_AllFrames()
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
end

function UF:CreateAndUpdateUF(unit)
	assert(unit, "No unit provided to create or update.")

	local frameName = E:StringTitle(unit)
	frameName = gsub(frameName, "t(arget)", "T%1")
	if not self[unit] then
		self[unit] = ElvUF:Spawn(unit, "ElvUF_"..frameName)
		self.units[unit] = unit
	end

	self[unit].Update = function()
		UF["Update_"..frameName.."Frame"](self, self[unit], self.db.units[unit])
	end

	if self.db.units[unit].enable then
		self[unit]:Enable()
		self[unit].Update()
		E:EnableMover(self[unit].mover:GetName())
	else
		self[unit]:Disable()
		E:DisableMover(self[unit].mover:GetName())
	end
end

function UF:LoadUnits()
	for _, unit in pairs(self.unitstoload) do
		self:CreateAndUpdateUF(unit)
	end
	self.unitstoload = nil

	for group, groupOptions in pairs(self.headerstoload) do
		local groupFilter, template, headerTemplate
		if type(groupOptions) == "table" then
			groupFilter, template, headerTemplate = unpack(groupOptions)
		end

		self:CreateAndUpdateHeaderGroup(group, groupFilter, template, nil, headerTemplate)
	end
	self.headerstoload = nil
end

--Re-applied after every full header refresh as well as on roster events: a
--config change rebuilds headers and would otherwise leave the gag off until the
--next time somebody joined or left.
local function ReapplyVisibility()
	if UF.UpdateHeaderVisibility then UF:UpdateHeaderVisibility() end
end

function UF:UpdateAllHeaders(event)
	local _, instanceType = IsInInstance()
	local ORD = ns.oUF_RaidDebuffs or oUF_RaidDebuffs
	if ORD then
		ORD:ResetDebuffData()

		--Commented out for as long as Settings/Filters/UnitFrame.lua was empty: with no
		--list to register, debuff_data stayed empty and the element could only ever pick a
		--dispellable debuff. The filter names are read from the RaidDebuff Indicator
		--options rather than hardcoded, which is what those two dropdowns already write to.
		--Guarded to the point of paranoia, because everything below this in the function is
		--what actually updates the party and raid headers. A nil here would raise and take
		--the frames with it, and "the aura filter lookup broke my party frames" is not a
		--connection anyone would make from the outside.
		local indicator = E.global.unitframe.raidDebuffIndicator
		local filters = E.global.unitframe.aurafilters

		if indicator and filters then
			local filterName = (instanceType == "party" or instanceType == "raid")
				and indicator.instanceFilter or indicator.otherFilter
			local filter = filterName and filters[filterName]

			if filter and filter.spells then
				ORD:RegisterDebuffs(filter.spells)
			end
		end
	end

	if E.private.unitframe.disabledBlizzardFrames.party then
		ElvUF:DisableBlizzard("party")
	end

	for group, header in pairs(self.headers) do
		if header.numGroups then
			UF.headerFunctions[group]:UpdateHeader(header)
		end
		UF.headerFunctions[group]:Update(header)

		if group == "party" or group == "raid" or group == "raid40" then
			--Update BuffIndicators on profile change as they might be using profile specific data
			--self:UpdateAuraWatchFromHeader(group)
		end
	end

	--LAST, after every header has been updated above. UpdateHeader and Update both
	--go through the branch that shows a header, so re-applying here is what stops a
	--profile change or a zone-in quietly putting the wrong one back on screen.
	ReapplyVisibility()
end

local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

local HandleFrame = function(baseName)
	local frame
	if type(baseName) == "string" then
		frame = _G[baseName]
	else
		frame = baseName
	end

	if(frame) then
		frame:UnregisterAllEvents()
		frame:Hide()

		-- Keep frame hidden without causing taint
		frame:SetParent(hiddenParent)

		local health = frame.healthbar
		if health then
			health:UnregisterAllEvents()
		end

		local power = frame.manabar
		if power then
			power:UnregisterAllEvents()
		end

		local spell = frame.spellbar
		if spell then
			spell:UnregisterAllEvents()
		end
	end
end

function ElvUF:DisableBlizzard(unit)
	if not unit then return end

	if(unit == "player") and E.private.unitframe.disabledBlizzardFrames.player then
		HandleFrame(PlayerFrame)
	elseif(unit == "pet") and E.private.unitframe.disabledBlizzardFrames.player then
		HandleFrame(PetFrame)
	elseif(unit == "target") and E.private.unitframe.disabledBlizzardFrames.target then
		HandleFrame(TargetFrame)
		HandleFrame(ComboFrame)
--	elseif(unit == "focus") and E.private.unitframe.disabledBlizzardFrames.focus then
--		HandleFrame(FocusFrame)
--		HandleFrame(FocusFrameToT)
	elseif(unit == "targettarget") and E.private.unitframe.disabledBlizzardFrames.target then
		HandleFrame(TargetofTargetFrame)
	elseif string.match(unit, "(party)%d?$") == "party" and E.private.unitframe.disabledBlizzardFrames.party then
		local id = string.match(unit, "party(%d)")
		if id then
			HandleFrame("PartyMemberFrame"..id)
		else
			for i = 1, 4 do
				HandleFrame(format("PartyMemberFrame%d", i))
			end
		end
		HandleFrame(PartyMemberBackground)
	end
end

local hasEnteredWorld = false
function UF:PLAYER_ENTERING_WORLD()
	if not hasEnteredWorld then
		--We only want to run Update_AllFrames once when we first log in or /reload
		self:Update_AllFrames()
		hasEnteredWorld = true

		--Reloading inside a raid does not reliably produce a roster event, so
		--without this the headers keep whatever visibility they were created with
		--until somebody joins or leaves. Delayed for the same reason the roster
		--handler is: the count is not answerable the instant we get here.
		self:ScheduleTimer("UpdateHeaderVisibility", 1)
	else
		local _, instanceType = IsInInstance()
		if instanceType ~= "none" then
			--We need to update headers when we zone into an instance
			UF:UpdateAllHeaders()
		end
	end
end

function UF:Initialize()
	self.db = E.db.unitframe
	self.thinBorders = self.db.thinBorders or E.PixelMode
	if E.private.unitframe.enable ~= true then return; end
	E.UnitFrames = UF

	self:UpdateColors()
	ElvUF:RegisterStyle("ElvUF", function(frame, unit)
		self:Construct_UF(frame, unit)
	end)

	self:LoadUnits()
	self:RegisterEvent("PLAYER_ENTERING_WORLD")

	--Which of party/raid/raid40 belongs on screen. Without these the headers only
	--re-evaluate when something else rebuilds them, so joining a raid would leave
	--the party frames up alongside it.
	self:RegisterEvent("RAID_ROSTER_UPDATE")
	self:RegisterEvent("PARTY_MEMBERS_CHANGED")
	self:UpdateHeaderVisibility()

	local ORD = ns.oUF_RaidDebuffs or oUF_RaidDebuffs
	if not ORD then return end
	ORD.ShowDispelableDebuff = true
	ORD.FilterDispellableDebuff = true

	-- self:UpdateRangeCheckSpells()
	-- self:RegisterEvent("LEARNED_SPELL_IN_TAB", "UpdateRangeCheckSpells")
end

function UF:ResetUnitSettings(unit)
	E:CopyTable(self.db.units[unit], P.unitframe.units[unit])

	if self.db.units[unit].buffs and self.db.units[unit].buffs.sizeOverride then
		self.db.units[unit].buffs.sizeOverride = P.unitframe.units[unit].buffs.sizeOverride or 0
	end

	if self.db.units[unit].debuffs and self.db.units[unit].debuffs.sizeOverride then
		self.db.units[unit].debuffs.sizeOverride = P.unitframe.units[unit].debuffs.sizeOverride or 0
	end

	self:Update_AllFrames()
end

function UF:ToggleForceShowGroupFrames(unitGroup, numGroup)
	for i = 1, numGroup do
		if self[unitGroup..i] and not self[unitGroup..i].isForced then
			UF:ForceShow(self[unitGroup..i])
		elseif self[unitGroup..i] then
			UF:UnforceShow(self[unitGroup..i])
		end
	end
end

local ignoreSettings = {
	["position"] = true,
	["playerOnly"] = true,
	["noConsolidated"] = true,
	["useBlacklist"] = true,
	["useWhitelist"] = true,
	["noDuration"] = true,
	["onlyDispellable"] = true,
	["useFilter"] = true
}

local ignoreSettingsGroup = {
	["visibility"] = true
}

local allowPass = {
	["sizeOverride"] = true
}

function UF:MergeUnitSettings(fromUnit, toUnit, isGroupUnit)
	local db = self.db.units
	local filter = ignoreSettings
	if isGroupUnit then
		filter = ignoreSettingsGroup
	end
	if fromUnit ~= toUnit then
		for option, value in pairs(db[fromUnit]) do
			if type(value) ~= "table" and not filter[option] then
				if db[toUnit][option] ~= nil then
					db[toUnit][option] = value
				end
			elseif not filter[option] then
				if type(value) == "table" then
					for opt, val in pairs(db[fromUnit][option]) do
						--local val = db[fromUnit][option][opt]
						if type(val) ~= "table" and not filter[opt] then
							if db[toUnit][option] ~= nil and (db[toUnit][option][opt] ~= nil or allowPass[opt]) then
								db[toUnit][option][opt] = val
							end
						elseif not filter[opt] then
							if type(val) == "table" then
								for o, v in pairs(db[fromUnit][option][opt]) do
									if not filter[o] then
										if db[toUnit][option] ~= nil and db[toUnit][option][opt] ~= nil and db[toUnit][option][opt][o] ~= nil then
											db[toUnit][option][opt][o] = v
										end
									end
								end
							end
						end
					end
				end
			end
		end
	else
		E:Print(L["You cannot copy settings from the same unit."])
	end

	self:Update_AllFrames()
end

local function updateColor(self, r, g, b)
	if not self.isTransparent then return end
	if self.backdrop then
		local _, _, _, a = self.backdrop:GetBackdropColor()
		self.backdrop:SetBackdropColor(r * 0.58, g * 0.58, b * 0.58, a)
	elseif self:GetParent().template then
		local _, _, _, a = self:GetParent():GetBackdropColor()
		self:GetParent():SetBackdropColor(r * 0.58, g * 0.58, b * 0.58, a)
	end

	if self.bg and self.bg:GetObjectType() == "Texture" and not self.bg.multiplier then
		self.bg:SetTexture(r * 0.35, g * 0.35, b * 0.35)
	end
end

function UF:ToggleTransparentStatusBar(isTransparent, statusBar, backdropTex, adjustBackdropPoints, invertBackdropTex)
	statusBar.isTransparent = isTransparent

	local statusBarTex = statusBar.texturePointer
	local statusBarOrientation = statusBar:GetOrientation()
	if isTransparent then
		if statusBar.backdrop then
			E:SetTemplate(statusBar.backdrop, "Transparent", nil, nil, nil, true)
			statusBar.backdrop.ignoreUpdates = true
		elseif statusBar:GetParent().template then
			E:SetTemplate(statusBar:GetParent(), "Transparent", nil, nil, nil, true)
			statusBar:GetParent().ignoreUpdates = true
		end

		statusBar:SetStatusBarTexture("")
		if statusBar.texture then statusBar.texture = statusBar:GetStatusBarTexture() end --Needed for Power element

		backdropTex:ClearAllPoints()
		if statusBarOrientation == "VERTICAL" then
			backdropTex:SetPoint("TOPLEFT", statusBar, "TOPLEFT")
			backdropTex:SetPoint("BOTTOMLEFT", statusBarTex, "TOPLEFT")
			backdropTex:SetPoint("BOTTOMRIGHT", statusBarTex, "TOPRIGHT")
		else
			backdropTex:SetPoint("TOPLEFT", statusBarTex, "TOPRIGHT")
			backdropTex:SetPoint("BOTTOMLEFT", statusBarTex, "BOTTOMRIGHT")
			backdropTex:SetPoint("BOTTOMRIGHT", statusBar, "BOTTOMRIGHT")
		end

		if invertBackdropTex then
			backdropTex:Show()
		end

		if not invertBackdropTex and not statusBar.hookedColor then
			hooksecurefunc(statusBar, "SetStatusBarColor", updateColor)
			statusBar.hookedColor = true
		end

		if backdropTex.multiplier then
			backdropTex.multiplier = 0.25
		end
	else
		if statusBar.backdrop then
			E:SetTemplate(statusBar.backdrop, "Default", nil, nil, not statusBar.PostCastStart and self.thinBorders, true)
			statusBar.backdrop.ignoreUpdates = nil
		elseif statusBar:GetParent().template then
			E:SetTemplate(statusBar:GetParent(), "Default", nil, nil, self.thinBorders, true)
			statusBar:GetParent().ignoreUpdates = nil
		end
		statusBar:SetStatusBarTexture(LSM:Fetch("statusbar", self.db.statusbar))
		if statusBar.texture then statusBar.texture = statusBar:GetStatusBarTexture() end

		if adjustBackdropPoints then
			backdropTex:ClearAllPoints()
			if statusBarOrientation == "VERTICAL" then
				backdropTex:SetPoint("TOPLEFT", statusBar, "TOPLEFT")
				backdropTex:SetPoint("BOTTOMLEFT", statusBarTex, "TOPLEFT")
				backdropTex:SetPoint("BOTTOMRIGHT", statusBarTex, "TOPRIGHT")
			else
				backdropTex:SetPoint("TOPLEFT", statusBarTex, "TOPRIGHT")
				backdropTex:SetPoint("BOTTOMLEFT", statusBarTex, "BOTTOMRIGHT")
				backdropTex:SetPoint("BOTTOMRIGHT", statusBar, "BOTTOMRIGHT")
			end
		end

		if invertBackdropTex then
			backdropTex:Hide()
		end

		if backdropTex.multiplier then
			backdropTex.multiplier = 0.25
		end
	end
end

local function InitializeCallback()
	UF:Initialize()
end

E:RegisterInitialModule(UF:GetName(), InitializeCallback)
