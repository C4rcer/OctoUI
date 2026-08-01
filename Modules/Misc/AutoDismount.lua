local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local pairs, type = pairs, type
local getn, tinsert, tremove = table.getn, table.insert, table.remove
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

	It dismounts and stops there, exactly as upstream does -- the second press is
	the player's. Re-issuing the refused spell was built and removed: the cast goes
	out, nothing refuses it, and nothing happens, which is what a silently discarded
	cast looks like rather than a rejected one. This client appears not to accept a
	cast that did not come from a real keypress. Upstream does not attempt it either,
	and neither does any addon installed here. Do not rebuild it without first
	establishing that an addon-issued cast can work at all on this client.
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

--Error strings that mean "you are mounted" or "you are shapeshifted", held by GLOBAL NAME
--rather than by value. Upstream listed the values directly, so any name this client does
--not define evaluated to nil and simply vanished from the table with nothing said -- which
--looks exactly like the feature not working. Names let a missing one be *reported*.
--Listing a name that does not exist here is free, so the list is deliberately generous.
local ERROR_GLOBALS = {
	--mounted
	"SPELL_FAILED_NOT_MOUNTED", "SPELL_FAILED_NOT_ON_MOUNTED", "ERR_ATTACK_MOUNTED",
	"ERR_TAXIPLAYERALREADYMOUNTED", "ERR_NOT_WHILE_MOUNTED", "ERR_MOUNT_ALREADYMOUNTED",
	"ERR_NO_ITEMS_WHILE_MOUNTED", "ERR_CANT_INTERACT_MOUNTED", "ERR_MOUNT_INVALIDMOUNTEE",
	--shapeshifted
	"SPELL_FAILED_NOT_SHAPESHIFT", "SPELL_FAILED_NO_ITEMS_WHILE_SHAPESHIFTED",
	"SPELL_NOT_SHAPESHIFTED", "SPELL_NOT_SHAPESHIFTED_NOSPACE", "ERR_ATTACK_SHAPESHIFTED",
	"ERR_CANT_INTERACT_SHAPESHIFTED", "ERR_NOT_WHILE_SHAPESHIFTED",
	"ERR_NO_ITEMS_WHILE_SHAPESHIFTED", "ERR_TAXIPLAYERSHAPESHIFTED", "ERR_MOUNT_SHAPESHIFTED"
}

--Populated at load and read by /octoui-dismount. The whole point is that the two ways this
--can fail -- an unrecognised error string, and a mount buff whose tooltip does not match
--MOUNT_STRINGS -- are both invisible from the outside otherwise.
M.DismountErrors = {}
M.DismountMissingGlobals = {}
M.DismountUnmatched = {}

local scanner, scannerName

local function PrepareScanner()
	if not scanner then
		scannerName = "ElvUI_DismountScanner"
		scanner = CreateFrame("GameTooltip", scannerName, UIParent, "GameTooltipTemplate")
	end

	--SetOwner every time, not once at creation. Every other tooltip scanner in this addon
	--does it per scan -- see PrepareScanner in Modules/NamePlates/Elements/Auras.lua -- and
	--a scanner that has lost its owner populates nothing while raising nothing.
	scanner:SetOwner(UIParent, "ANCHOR_NONE")
	scanner:ClearLines()

	return scanner
end

--True when the tooltip for player buff `index` contains any of MOUNT_STRINGS
local function BuffLooksLikeMount(index)
	PrepareScanner()
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
	local errors = M.DismountErrors

	for i = 1, getn(ERROR_GLOBALS) do
		local name = ERROR_GLOBALS[i]
		local text = _G[name]

		if type(text) == "string" and text ~= "" then
			errors[text] = name
		else
			tinsert(M.DismountMissingGlobals, name)
		end
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

		if not errors[arg1] then
			--Remember what did not match, so one failed attempt is enough to identify the
			--string instead of another round of guessing at which global it ought to be.
			--Newest first, capped, and duplicates collapsed so a spammed error cannot push
			--everything else out.
			local unmatched = M.DismountUnmatched
			for u = 1, getn(unmatched) do
				if unmatched[u] == arg1 then return end
			end

			tinsert(unmatched, 1, arg1)
			while getn(unmatched) > 8 do
				tremove(unmatched)
			end

			return
		end

		for i = 0, 31 do
			if BuffLooksLikeMount(i) or BuffLooksLikeShapeshift(i) then
				CancelPlayerBuff(i)
				M.DismountNoBuffFound = nil
				return
			end
		end

		--Matched the error, found nothing to cancel. Almost always means the mount's
		--tooltip wording is not in MOUNT_STRINGS; /octoui-dismount lists what it can see.
		M.DismountNoBuffFound = true
	end)

	M.AutoDismountFrame = f
end

--Which buffs the mount and shapeshift checks currently match. Called by the report while
--the player is actually mounted, which is the only time the answer means anything.
function M:DismountScanBuffs()
	local mounts, shifts = {}, {}

	for i = 0, 31 do
		if GetPlayerBuffTexture(i) then
			if BuffLooksLikeMount(i) then
				tinsert(mounts, i)
			elseif BuffLooksLikeShapeshift(i) then
				tinsert(shifts, i)
			end
		end
	end

	return mounts, shifts
end
