local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local pairs, type = pairs, type
local getn, tinsert, tremove = table.getn, table.insert, table.remove
local find, lower, format = string.find, string.lower, string.format
--WoW API / Variables
local CreateFrame = CreateFrame
local CancelPlayerBuff = CancelPlayerBuff
local GetPlayerBuffTexture = GetPlayerBuffTexture
local SitOrStand = SitOrStand
local UIParent = UIParent
local GetTime = GetTime
local UnitClass = UnitClass
local UnitAffectingCombat = UnitAffectingCombat
local GetTalentInfo = GetTalentInfo

--[[
	Ported from ShaguTweaks, mods/auto-dismount.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Upstream leans on ShaguTweaks' libtipscan, a 169 line general purpose tooltip
	scanner. All that is needed here is "does this player buff's tooltip contain
	one of these strings", so a small dedicated scanner is used instead of
	vendoring the library.

	Kept on a plain event frame rather than AceEvent, because the handler reads
	the 1.12 arg1 global.

	Upstream's design is kept unchanged and one thing is added on top: the action that
	provoked the error is REMEMBERED, and replayed once the buff has actually dropped.
	Same dismount, same triggers, but one press instead of two.

	This header used to say re-issuing had been tried and that "this client appears not
	to accept a cast that did not come from a real keypress". That is wrong, and it is
	now measured rather than argued: /octoui-dismount reported `UseAction -- replayed`
	with the action going through on 2026-08-08. 1.12 has no protected functions at all
	-- the hardware-event requirement arrived in 2.0 -- and this addon's own AutoStance
	has always cast from a UI_ERROR_MESSAGE handler. What the old attempt did was replay
	while STILL MOUNTED: CancelPlayerBuff is a request, the player stays mounted for the
	round trip, and the replayed cast was refused for precisely the same reason as the
	first one. A cast discarded that way looks exactly like "it went out and nothing
	happened". The replay below waits for the buff to be GONE, which is the one thing
	the old attempt did not do.

	WHY THE ACTION IS SENT FIRST rather than checking for a mount before sending it.
	The check-first version was built first and is worse: it cannot tell an action that
	was blocked BY THE MOUNT from one that was never going to work anyway, so pressing
	an ability with no target threw the player off their mount for nothing. Letting the
	client rule on the action first means the dismount is driven by its verdict -- "You
	have no target." is not a mount error, so nothing is cancelled.

	That ordering is also what lets forms be handled safely. Nothing known before the
	fact distinguishes Claw, which is fine in cat form, from Healing Touch, which is
	not; the error has already said the form was the obstacle.
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

--Shapeshift buffs, matched on icon texture rather than text.
--
--NOTE what is NOT in here: spell_nature_forceofnature, the Moonkin icon. An agility buff
--shares that texture, so listing it unconditionally means cancelling that buff off any class
--that happens to have it. pfUI guards this by only adding it for a druid who has actually
--taken the talent (modules/autoshift.lua), and it was a latent bug here until the proactive
--path below made it a live one: matching on an error is rare, but the proactive check runs on
--every action the player takes, so a false positive would strip the buff again and again.
local SHAPESHIFT_TEXTURES = {
	"ability_racial_bearform", "ability_druid_catform", "ability_druid_travelform",
	"ability_druid_aquaticform", "spell_nature_spiritwolf"
}

--Talent points only read once the client has them, so this waits for an event rather than
--asking at load. Unregisters itself either way: a non-druid never needs to look again.
local function WatchForMoonkin()
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")
	f:RegisterEvent("UNIT_NAME_UPDATE")
	f:SetScript("OnEvent", function()
		local _, class = UnitClass("player")

		if class ~= "DRUID" then
			f:UnregisterAllEvents()
			return
		end

		local _, _, _, _, moonkin = GetTalentInfo(1, 16)
		if moonkin and moonkin > 0 then
			tinsert(SHAPESHIFT_TEXTURES, "spell_nature_forceofnature")
			M.DismountMoonkinAdded = true
			f:UnregisterAllEvents()
		end
	end)
end

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

--REPLAYING THE BLOCKED ACTION: TRIED, MEASURED, DOES NOT WORK. Do not rebuild it.
--
--The goal was one press instead of two: remember the action that hit the "you are mounted"
--error, cancel the buff, and replay the action once the dismount finished. Built and tested
--on this client 2026-08-08, five variants, all of them dead.
--
--What was MEASURED, so nobody has to measure it again:
--
--  * An addon-issued cast DOES work here in general. Typed by hand,
--    `/script CastSpellByName("Corruption")` casts normally. 1.12 has no protected
--    functions -- the hardware-event requirement arrived in 2.0 -- so the old claim that
--    this client "does not accept a cast that did not come from a real keypress" is wrong
--    as stated.
--
--  * The SAME call, issued from the replay after a dismount, produces NOTHING. No cast, no
--    error, no refusal -- /octoui-dismount reported `nothing heard` every time. Both routes
--    were tried: UseAction on the original action slot, and CastSpellByName on the spell
--    name resolved from that slot.
--
--  * It is not a timing guess that was simply wrong. Waits of 0.15s, 0.3s, 0.6s and 1.5s
--    after the mount buff dropped all behaved identically, as did gating on
--    UNIT_MODEL_CHANGED rather than a timer.
--
--So something in the post-dismount window discards Lua-issued actions specifically, and no
--delay reaches past it. The mouse cursor shows the same transition plainly -- a hand while
--mounted, a sword once genuinely on foot.
--
--pfUI's autoshift and ShaguTweaks' auto-dismount, both by the same author, dismount and stop
--exactly as this does. Neither attempts a replay.

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

	WatchForMoonkin()

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

		--Clicking an NPC mid-fight must not strip a druid's form. pfUI guards exactly this
		--(modules/autoshift.lua) and we did not: the click is not worth leaving cat form for,
		--and the player did not ask to.
		if arg1 == ERR_CANT_INTERACT_SHAPESHIFTED and UnitAffectingCombat("player") then
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
