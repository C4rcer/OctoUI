local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local pairs = pairs
local find, lower = string.find, string.lower
--WoW API / Variables
local CreateFrame = CreateFrame
local CancelPlayerBuff = CancelPlayerBuff
local GetPlayerBuffTexture = GetPlayerBuffTexture
local SitOrStand = SitOrStand
local UIParent = UIParent

--[[
	Ported from ShaguTweaks, mods/auto-dismount.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Upstream leans on ShaguTweaks' libtipscan, a 169 line general purpose tooltip
	scanner. All that is needed here is "does this player buff's tooltip contain
	one of these strings", so a small dedicated scanner is used instead of
	vendoring the library.

	Kept on a plain event frame rather than AceEvent, because the handler reads
	the 1.12 arg1 global.
]]

--Mount tooltip texts, including the Turtle/OctoWoW riding-skill wording
local MOUNT_STRINGS = {
	--deDE
	"^Erhöht Tempo um (.+)%%",
	--enUS
	"^Increases speed by (.+)%%",
	--esES
	"^Aumenta la velocidad en un (.+)%%",
	--frFR
	"^Augmente la vitesse de (.+)%%",
	--ruRU
	"^Скорость увеличена на (.+)%%",
	--koKR
	"^이동 속도 (.+)%%만큼 증가",
	--zhCN
	"^速度提高(.+)%%",
	--turtle-wow
	"speed based on", "Slow and steady...", "Riding",
	"Lento y constante...", "Aumenta la velocidad según tu habilidad de Montar.",
	"根据您的骑行技能提高速度。", "根据骑术技能提高速度。", "又慢又稳......"
}

--Shapeshift buffs, matched on icon texture rather than text
local SHAPESHIFT_TEXTURES = {
	"ability_racial_bearform", "ability_druid_catform", "ability_druid_travelform",
	"spell_nature_forceofnature", "ability_druid_aquaticform", "spell_nature_spiritwolf"
}

local scanner, scannerName

local function BuildScanner()
	scannerName = "ElvUI_DismountScanner"
	scanner = CreateFrame("GameTooltip", scannerName, UIParent, "GameTooltipTemplate")
	scanner:SetOwner(UIParent, "ANCHOR_NONE")
end

--True when the tooltip for player buff `index` contains any of MOUNT_STRINGS
local function BuffLooksLikeMount(index)
	if not scanner then return false end

	scanner:ClearLines()
	scanner:SetPlayerBuff(index)

	for line = 1, scanner:NumLines() do
		local fontString = _G[scannerName.."TextLeft"..line]
		local text = fontString and fontString:GetText()

		if text then
			for _, pattern in pairs(MOUNT_STRINGS) do
				if find(text, pattern) then return true end
			end
		end
	end

	return false
end

local function BuffLooksLikeShapeshift(index)
	local texture = GetPlayerBuffTexture(index)
	if not texture then return false end

	texture = lower(texture)
	for _, name in pairs(SHAPESHIFT_TEXTURES) do
		if find(texture, name) then return true end
	end

	return false
end

function M:LoadAutoDismount()
	BuildScanner()

	--Errors that mean "you are mounted or shapeshifted". Built at load because
	--these are FrameXML globals, and any that this client lacks are simply absent
	--from the table rather than comparing against nil.
	local errors = {}
	local candidates = {
		SPELL_FAILED_NOT_MOUNTED, ERR_ATTACK_MOUNTED, ERR_TAXIPLAYERALREADYMOUNTED,
		SPELL_FAILED_NOT_SHAPESHIFT, SPELL_FAILED_NO_ITEMS_WHILE_SHAPESHIFTED,
		SPELL_NOT_SHAPESHIFTED, SPELL_NOT_SHAPESHIFTED_NOSPACE,
		ERR_CANT_INTERACT_SHAPESHIFTED, ERR_NOT_WHILE_SHAPESHIFTED,
		ERR_NO_ITEMS_WHILE_SHAPESHIFTED, ERR_TAXIPLAYERSHAPESHIFTED,
		ERR_MOUNT_SHAPESHIFTED
	}
	for _, errorstring in pairs(candidates) do
		errors[errorstring] = true
	end

	local f = CreateFrame("Frame", "ElvUI_AutoDismount")
	f:RegisterEvent("UI_ERROR_MESSAGE")
	f:SetScript("OnEvent", function()
		if not E.db.general.autoDismount then return end
		if not arg1 then return end

		--Stand up
		if arg1 == SPELL_FAILED_NOT_STANDING then
			SitOrStand()
			return
		end

		if not errors[arg1] then return end

		for i = 0, 31 do
			if BuffLooksLikeMount(i) or BuffLooksLikeShapeshift(i) then
				CancelPlayerBuff(i)
				return
			end
		end
	end)

	M.AutoDismountFrame = f
end
