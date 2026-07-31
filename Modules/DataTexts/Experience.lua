local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local DT = E:GetModule("DataTexts");

--Cache global variables
--Lua functions
local floor = math.floor
local format, join = string.format, string.join
--WoW API / Variables
local UnitXP, UnitXPMax, UnitLevel = UnitXP, UnitXPMax, UnitLevel
local GetXPExhaustion = GetXPExhaustion
local ToggleCharacter = ToggleCharacter

--[[
	Progress through the current level, with an estimate of how many more kills it
	will take. Modelled on what pfUI put in the same spot, since that is what this
	panel is replacing: a percentage, and a dim [n] beside it.

	The kill estimate is deliberately naive -- it divides the experience still needed
	by the size of the *last* gain. That makes it exact only while grinding the same
	mob, and it is why the number jumps around after a quest turn-in. Vanilla offers
	nothing better: there is no per-mob experience table to consult, only what the
	last award happened to be.
]]

local displayString, restedString = "", ""
local lastPanel
local lastXP, killsLeft

local function KillEstimate()
	local current = UnitXP("player")
	local max = UnitXPMax("player")

	--A level up resets the bar, so a negative delta says nothing about kill size
	if lastXP and current > lastXP then
		local gained = current - lastXP
		killsLeft = floor((max - current) / gained)
	end

	lastXP = current

	return killsLeft
end

local function OnEvent(self)
	lastPanel = self

	local max = UnitXPMax("player")

	--Max level reports a maximum of zero, and dividing by it is how a datatext takes
	--the whole panel down with it
	if not max or max <= 0 then
		self.text:SetText(join("", L["Experience"], ": ", MAX_LEVEL or UnitLevel("player") or ""))
		return
	end

	local percent = floor((UnitXP("player") / max) * 100)
	local kills = KillEstimate()

	--Rested is worth seeing at a glance, so it colours the number rather than adding
	--another label to a panel that has room for three things
	local text = format(GetXPExhaustion() and restedString or displayString, percent)

	if kills and kills > 0 then
		text = text.."|cff555555 ["..kills.."]|r"
	end

	self.text:SetText(text)
end

local function OnClick()
	ToggleCharacter("PaperDollFrame")
end

local function OnEnter(self)
	DT:SetupTooltip(self)

	local current, max = UnitXP("player"), UnitXPMax("player")

	if not max or max <= 0 then
		DT.tooltip:AddLine(L["Experience"])
		DT.tooltip:Show()
		return
	end

	DT.tooltip:AddDoubleLine(L["Experience"], format("%d / %d", current, max), 1, 1, 1)
	DT.tooltip:AddDoubleLine(L["Remaining"], format("%d", max - current), 1, 1, 1)

	local rested = GetXPExhaustion()
	if rested and rested > 0 then
		DT.tooltip:AddDoubleLine(L["Rested"], format("%d (%d%%)", rested, (rested / max) * 100), 1, 1, 1)
	end

	if killsLeft and killsLeft > 0 then
		DT.tooltip:AddDoubleLine(L["Kills to Level"], killsLeft, 1, 1, 1)
	end

	DT.tooltip:Show()
end

local function ValueColorUpdate(hex)
	displayString = join("", L["Experience"], ": ", hex, "%d%%|r")

	--rested keeps its own colour rather than the user's value colour, because the
	--whole point of it is to stand out from the ordinary case
	restedString = join("", L["Experience"], ": |cffaaaaff%d%%|r")

	if lastPanel ~= nil then
		OnEvent(lastPanel, "ELVUI_COLOR_UPDATE")
	end
end
E.valueColorUpdateFuncs[ValueColorUpdate] = true

DT:RegisterDatatext("Experience", {"PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD", "UPDATE_EXHAUSTION"}, OnEvent, nil, OnClick, OnEnter, nil, L["Experience"])
