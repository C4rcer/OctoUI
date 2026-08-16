local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Minimap");

--Cache global variables
--Lua functions
local _G = _G
local getn, tinsert = table.getn, table.insert
local find, lower = string.find, string.lower
local tostring, pcall = tostring, pcall
local ceil, mod = math.ceil, math.mod
local select = select
--WoW API / Variables
local CreateFrame = CreateFrame

--[[
	Collects third-party minimap buttons into a row beneath the minimap.

	Addon minimap buttons place themselves around the edge of a CIRCLE, because
	that is what the Blizzard minimap is. OctoUI's minimap is square, so those
	buttons end up scattered over and around it. There is no upstream ElvUI
	feature for this; ElvUI only repositions Blizzard's own minimap children.

	Buttons are found by walking Minimap's children and rejecting the ones we
	know belong to Blizzard, the client, or us. That direction matters: a
	whitelist of known addons would silently miss anything not on it, whereas a
	blacklist adopts unknown buttons, which is the useful default.
]]

--Blizzard and client-owned children of Minimap. Anything here is positioned by
--the Minimap module (or deliberately hidden) and must not be collected.
local ignore = {
	["MinimapBackdrop"] = true,
	["MinimapBorder"] = true,
	["MinimapBorderTop"] = true,
	["MinimapNorthTag"] = true,
	["MinimapToggleButton"] = true,
	["MinimapZoomIn"] = true,
	["MinimapZoomOut"] = true,
	["MinimapZoneTextButton"] = true,
	["MinimapCluster"] = true,
	["MiniMapWorldMapButton"] = true,
	["MiniMapMailFrame"] = true,
	["MiniMapMailBorder"] = true,
	["MiniMapBattlefieldFrame"] = true,
	["MiniMapBattlefieldBorder"] = true,
	["MiniMapTracking"] = true,
	["MiniMapTrackingFrame"] = true,
	["MiniMapTrackingButton"] = true,
	["MiniMapMeetingStoneFrame"] = true,
	["MiniMapLFGFrame"] = true,
	["MiniMapPing"] = true,
	["MiniMapVoiceChatFrame"] = true,
	["MiniMapInstanceDifficulty"] = true,
	["GameTimeFrame"] = true,
	["TimeManagerClockButton"] = true,
	["QuestTimerFrame"] = true,
	["FarmModeMap"] = true,
	["Minimap"] = true,
	--Turtle/OctoWoW's own battlefield icon, the server's equivalent of
	--MiniMapBattlefieldFrame. Positioned with the Blizzard icons, not collected.
	["TWMiniMapBattlefieldFrame"] = true
}

--Name patterns that are emphatically NOT buttons, whatever their object type.
--Map PINS are the trap here: pfQuest spawns pfMiniMapPin1..n as real Buttons
--parented to Minimap, one per tracked quest objective. Collecting those would
--drag every quest marker off the map into the bar and, because collection
--pins SetPoint, stop pfQuest from ever placing them again.
local ignorePatterns = {
	"^pfMiniMapPin",
	"MiniMapPin%d",
	"MapPin%d",
	"Pin%d+$"
}

--Regions worth hiding when tidying a collected button: the round gold ring and
--the plate behind it. Matched on the region's texture path rather than its
--name, because addon authors name these inconsistently. The icon itself is
--never matched, so a button cannot end up blank.
local borderTextures = {
	"minimap%-trackingborder",
	"ui%-minimap%-border",
	"minimapbutton",
	"trackingborder",
	"minimap%-trackingbackground",
	"ui%-minimap%-background"
}

local collected = {}
local bar

--1.12 does NOT return nil for a handler the object type does not define, it
--raises "<frame> doesn't have a \"OnClick\" script". Frames have no OnClick, so
--simply asking is fatal. pcall makes the question safe to ask of anything.
local function HasScript(frame, handler)
	if not frame or not frame.GetScript then return false end
	local ok, script = pcall(frame.GetScript, frame, handler)
	return (ok and script) and true or false
end

local function IsCollectable(child)
	if not child or not child.GetName then return false end

	local name = child:GetName()
	if not name or ignore[name] then return false end

	--Our own frames, and anything the Minimap module made. A module that wants
	--its button treated like every other addon's opts in with octoCollect --
	--without that escape hatch an OctoUI button is the ONLY one left sitting on
	--the minimap while the rest line up in the bar, which looks like a bug.
	if find(name, "^ElvUI") or find(name, "^OctoUI") or find(name, "^Elv_") then
		return child.octoCollect and true or false
	end

	for i = 1, getn(ignorePatterns) do
		if find(name, ignorePatterns[i]) then return false end
	end

	if not child.GetObjectType then return false end
	local objType = child:GetObjectType()

	if objType == "Button" or objType == "CheckButton" then
		return true
	end

	--Plenty of minimap buttons are plain Frames rather than Buttons. Accept one
	--when it responds to the mouse, or when it is a container wrapping a real
	--button (AtlasLootMinimapButtonFrame and AtlasCFMButtonFrame are both that
	--shape), which keeps purely visual overlays out of the bar.
	if objType == "Frame" then
		if HasScript(child, "OnMouseDown") or HasScript(child, "OnMouseUp")
		or HasScript(child, "OnClick") then
			return true
		end

		if child.GetChildren then
			local kids = {child:GetChildren()}
			for i = 1, getn(kids) do
				local kid = kids[i]
				local kidType = kid and kid.GetObjectType and kid:GetObjectType()
				if kidType == "Button" or kidType == "CheckButton" then
					return true
				end
			end
		end
	end

	return false
end

local function TidyButton(button)
	if not E.db.general.minimap.buttonBar.stripBorders then return end
	if not button.GetNumRegions then return end

	for i = 1, button:GetNumRegions() do
		local region = select(i, button:GetRegions())
		if region and region.GetObjectType and region:GetObjectType() == "Texture"
		and region.GetTexture then
			local texture = region:GetTexture()
			if texture then
				texture = lower(texture)
				for j = 1, getn(borderTextures) do
					if find(texture, borderTextures[j]) then
						region:SetTexture(nil)
						break
					end
				end
			end
		end
	end
end

function M:CollectMinimapButtons()
	if not bar or not Minimap then return end

	--Not every button parents to Minimap itself: MinimapBackdrop and
	--MinimapCluster are both common choices, so sweep all three.
	local children = {}
	local parents = {Minimap, _G["MinimapBackdrop"], _G["MinimapCluster"]}
	for p = 1, getn(parents) do
		local parent = parents[p]
		if parent and parent.GetChildren then
			local kids = {parent:GetChildren()}
			for k = 1, getn(kids) do
				tinsert(children, kids[k])
			end
		end
	end

	for i = 1, getn(children) do
		local child = children[i]
		if IsCollectable(child) and not child.octoCollected then
			child.octoCollected = true
			tinsert(collected, child)

			child:SetParent(bar)
			child:ClearAllPoints()
			--Buttons re-anchor themselves to the minimap edge on their own
			--events, which would undo the layout the moment anything fires.
			--Pin the position after we have set it.
			child.octoSetPoint = child.SetPoint
			child.SetPoint = E.noop

			if child.SetFrameStrata then child:SetFrameStrata("LOW") end
			TidyButton(child)
		end
	end

	M:LayoutMinimapButtons()
end

function M:LayoutMinimapButtons()
	if not bar then return end

	local db = E.db.general.minimap.buttonBar
	local count = getn(collected)

	--Only the bar is shown or hidden. Do NOT touch the mover here: E:DisableMover
	--removes the entry from E.CreatedMovers, and this runs during module init,
	--before E:LoadMovers has walked that table to build the actual mover frame.
	--Disabling it at that point means the mover is never created at all.
	if not db.enable or count == 0 then
		bar:Hide()
		return
	end

	local size, spacing = db.buttonSize, db.spacing
	local perRow = db.buttonsPerRow
	if perRow < 1 then perRow = 1 end
	if count < perRow then perRow = count end

	local rows = ceil(count / perRow)

	for i = 1, count do
		local button = collected[i]
		local col = mod(i - 1, perRow)
		local row = ceil(i / perRow) - 1

		E:Size(button, size)

		--SetPoint is noop'd on these, so go through the saved original
		local setPoint = button.octoSetPoint or button.SetPoint
		setPoint(button, "TOPLEFT", bar, "TOPLEFT",
			E:Scale(spacing + col * (size + spacing)),
			-E:Scale(spacing + row * (size + spacing)))

		button:Show()
	end

	E:Size(bar,
		(size * perRow) + (spacing * (perRow + 1)),
		(size * rows) + (spacing * (rows + 1)))

	bar:Show()
end

function M:UpdateMinimapButtonBar()
	M:LayoutMinimapButtons()
end

function M:LoadMinimapButtonBar()
	if not Minimap then return end

	--Gated on the setting rather than only hiding the bar afterwards, so that
	--turning the feature off is a genuine escape hatch: nothing is created, no
	--button is reparented, and nothing here can run at all. Needs a reload to
	--turn back on, which the option says.
	if not E.db.general.minimap.buttonBar.enable then return end

	bar = CreateFrame("Frame", "OctoUI_MinimapButtonBar", E.UIParent)
	bar:SetFrameStrata("BACKGROUND")
	--SetTemplate rather than CreateBackdrop: the bar is a plain container and
	--does not need a second frame behind it, and this keeps one less CreateFrame
	--on a path that runs during module init.
	E:SetTemplate(bar, "Transparent")
	E:Size(bar, 100, 26)
	--Default position: tucked under the minimap, which is the whole point.
	E:Point(bar, "TOPRIGHT", MMHolder or Minimap, "BOTTOMRIGHT", 0, -3)
	bar:Hide()

	E:CreateMover(bar, "MinimapButtonBarMover", L["Minimap Buttons"], nil, nil, nil, "ALL,GENERAL")

	--pcall'd: a failure in this first sweep must not stop the timers below being
	--scheduled, or the bar can never recover on a later pass. This is exactly
	--what happened before: the sweep threw here and took the timers, the flags
	--and the diagnostics with it.
	local ok, err = pcall(M.CollectMinimapButtons, M)
	if not ok then
		E:Print("|cffff0000minimap sweep failed:|r "..tostring(err))
	end

	--Addons add their buttons at wildly different times: some at load, some on
	--PLAYER_LOGIN, some the first time their feature is used. Sweep a few times
	--after login rather than assuming one moment catches them all.
	M:ScheduleTimer("CollectMinimapButtons", 2)
	M:ScheduleTimer("CollectMinimapButtons", 5)
	M:ScheduleTimer("CollectMinimapButtons", 10)
	M:ScheduleTimer("CollectMinimapButtons", 20)
end
