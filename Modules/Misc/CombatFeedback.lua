local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local pairs = pairs
--WoW API / Variables
local CreateFrame = CreateFrame
local GetTime = GetTime

--[[
	Ported from ShaguTweaks-extras, mods/raid-combat-feedback.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Upstream registers a component through ShaguTweaks' own raid frame system. The
	work is done by Blizzard's FrameXML helpers, CombatFeedback_OnCombatEvent and
	CombatFeedback_OnUpdate, which read their state off `this`. That means each
	unit needs its own frame carrying feedbackText / feedbackFontHeight /
	feedbackStartTime, rather than one shared handler, or `this` points at the
	wrong frame and the numbers land on the wrong unit.

	Attached to ElvUI's player and target frames, deferred to PLAYER_ENTERING_WORLD
	because they do not exist when Misc initialises.
]]

local FONT_HEIGHT = 12

local UNITS = {
	["ElvUF_Player"] = "player",
	["ElvUF_Target"] = "target"
}

local function OnEvent()
	if arg1 ~= this.feedbackUnit then return end
	CombatFeedback_OnCombatEvent(arg2, arg3, arg4, arg5)
end

local function OnUpdate()
	CombatFeedback_OnUpdate(arg1)
end

local function CreateFeedback(parent, unit)
	local f = CreateFrame("Frame", nil, parent)
	f:SetAllPoints(parent)
	f.feedbackUnit = unit

	f.feedbackText = f:CreateFontString(nil, "OVERLAY")
	f.feedbackText:SetFont(DAMAGE_TEXT_FONT, FONT_HEIGHT, "OUTLINE")
	f.feedbackText:SetPoint("CENTER", parent, "CENTER", 0, 0)

	--Both fields are read directly by the FrameXML helpers
	f.feedbackFontHeight = FONT_HEIGHT
	f.feedbackStartTime = GetTime()

	f:RegisterEvent("UNIT_COMBAT")
	f:SetScript("OnEvent", OnEvent)
	f:SetScript("OnUpdate", OnUpdate)

	return f
end

function M:AttachCombatFeedback()
	if self.CombatFeedbackFrames then return end

	--FrameXML helpers. Absent means this client cannot support the feature.
	if not CombatFeedback_OnCombatEvent or not CombatFeedback_OnUpdate then return end

	local frames = {}
	for frameName, unit in pairs(UNITS) do
		local parent = _G[frameName]
		if parent then
			frames[unit] = CreateFeedback(parent, unit)
		end
	end

	self.CombatFeedbackFrames = frames
end

function M:UpdateCombatFeedback()
	if not self.CombatFeedbackFrames then return end

	local show = E.db.general.combatFeedback
	for _, frame in pairs(self.CombatFeedbackFrames) do
		if show then
			frame:Show()
		else
			frame:Hide()
		end
	end
end

function M:LoadCombatFeedback()
	local loader = CreateFrame("Frame")
	loader:RegisterEvent("PLAYER_ENTERING_WORLD")
	loader:SetScript("OnEvent", function()
		if not E.db.general.combatFeedback then return end

		M:AttachCombatFeedback()
		M:UpdateCombatFeedback()
	end)
end
