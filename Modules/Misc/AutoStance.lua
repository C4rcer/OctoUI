local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local gsub, gfind = string.gsub, string.gfind
local pairs = pairs
--WoW API / Variables
local CreateFrame = CreateFrame
local CastSpellByName = CastSpellByName
local strsplit = strsplit

--[[
	Ported from ShaguTweaks, mods/auto-stance.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Kept on a plain event frame rather than AceEvent, because the handler reads the
	1.12 arg1 global and this way it behaves exactly as it did upstream.
]]

function M:LoadAutoStance()
	--FrameXML global. Guarded because a missing constant would take out the whole
	--Misc Initialize, and this feature is not worth that.
	if not SPELL_FAILED_ONLY_SHAPESHIFT then return end

	local f = CreateFrame("Frame", "ElvUI_AutoStance")
	f.scanString = gsub(SPELL_FAILED_ONLY_SHAPESHIFT, "%%s", "(.+)")

	f:RegisterEvent("UI_ERROR_MESSAGE")
	f:SetScript("OnEvent", function()
		if not E.db.general.autoStance then return end
		if not arg1 then return end

		--The error names every stance that would allow the cast, comma separated
		for stances in gfind(arg1, f.scanString) do
			for _, stance in pairs({strsplit(",", stances)}) do
				CastSpellByName(gsub(stance, "^%s*(.-)%s*$", "%1"))
			end
		end
	end)

	M.AutoStanceFrame = f
end
