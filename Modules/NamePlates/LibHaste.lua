local E, L, V, P, G = unpack(ElvUI)
local mod = E:GetModule("NamePlates")

--[[
	Casting speed, reconstructed by tooltip scanning.

	1.12 has no haste API at all -- nothing returns a casting speed number -- so the
	only way to know it is to read the same tooltips the player reads: equipped gear,
	active buffs, and talents. Everything matched here is the *client's own* tooltip
	text, not another addon's data.

	This exists because OctoWoW scales damage-over-time effects with casting speed.
	Vanilla does not: haste there only shortens cast time, and DoT ticks are fixed.
	This server's talents (the warlock's Rapid Deterioration is the one confirmed)
	say "casting speed increase effects increase the tick speed of your damage over
	time and channeled spells with 100% efficiency, reducing their duration", which
	makes duration = base / (1 + castingSpeed). LibDebuff applies that.

	BetterCharacterStats computes the same number for its character sheet and is the
	addon to disable if you want only one of these scanning your gear. It is not a
	dependency and its code is not used here -- it ships without a licence, so
	nothing of it could be reused even if we wanted to.

	Recomputed lazily and only when something that could change it fires, because a
	full pass is 19 item tooltips plus every buff plus the talent trees.
]]

local pairs, tonumber, type = pairs, tonumber, type
local find, lower = string.find, string.lower

local GetInventoryItemLink = GetInventoryItemLink
local GetNumTalentTabs, GetNumTalents, GetTalentInfo = GetNumTalentTabs, GetNumTalents, GetTalentInfo
local GetPlayerBuff = GetPlayerBuff

local lib = CreateFrame("Frame", "OctoUI_LibHaste")
mod.LibHaste = lib

lib.castingSpeed = 0
lib.scalesDots = false
lib.dirty = true

--The client's own wordings for a casting speed increase. Matched case-insensitively
--against every tooltip line, so a new item phrased slightly differently only needs a
--line adding here. Melee-only haste ("attack speed by N%") is deliberately absent:
--it does not touch casting.
local CASTING_SPEED = {
	"increases your attack and casting speed by (%d+)%%",
	"increases your casting speed by (%d+)%%",
	"increases attack and casting speed by (%d+)%%",
	"increases attack and spell casting speed by (%d+)%%",
	"increases casting and attack speed by (%d+)%%",
	"increases casting speed by (%d+)%%",
	"increases your spell casting speed by (%d+)%%",
	"spell casting speed by (%d+)%%",
	"casting speed increased by (%d+)%%",
	"attack and casting speed increased by (%d+)%%",
	"^%+(%d+)%% haste",
}

--A talent that makes casting speed shorten damage-over-time effects. Matched on the
--effect rather than on a spell name, so any class whose tree has an equivalent picks
--it up without a per-class list.
local DOT_SCALING = {
	"tick speed",
	"reducing their duration",
}

local scanner, lines
local function PrepareScanner()
	if not scanner then
		scanner = CreateFrame("GameTooltip", "OctoUI_HasteScanner", nil, "GameTooltipTemplate")
		lines = {}
		for i = 1, 30 do
			lines[i] = _G["OctoUI_HasteScannerTextLeft"..i]
		end
	end

	scanner:SetOwner(E.UIParent, "ANCHOR_NONE")
	scanner:ClearLines()

	return scanner
end

--Returns the casting speed percentage found on the tooltip currently loaded into the
--scanner, and whether it mentioned DoT scaling.
local function ReadScanner()
	local speed, scales = 0, false

	for i = 1, scanner:NumLines() do
		local fs = lines[i]
		local text = fs and fs:GetText()
		if text then
			text = lower(text)

			for _, pattern in pairs(CASTING_SPEED) do
				local _, _, value = find(text, pattern)
				if value then
					speed = speed + (tonumber(value) or 0)
					break --one match per line, or "attack and casting speed" double counts
				end
			end

			for _, pattern in pairs(DOT_SCALING) do
				if find(text, pattern) then scales = true break end
			end
		end
	end

	return speed, scales
end

function lib:Rescan()
	local speed, scales = 0, false

	--equipped gear, slots 1-19
	for slot = 1, 19 do
		if GetInventoryItemLink("player", slot) then
			local tip = PrepareScanner()
			tip:SetInventoryItem("player", slot)
			local s = ReadScanner()
			speed = speed + s
		end
	end

	--active buffs. 1.12 indexes these through GetPlayerBuff rather than 1..n
	local i = 0
	while true do
		local buffIndex = GetPlayerBuff(i, "HELPFUL")
		if not buffIndex or buffIndex < 0 then break end

		local tip = PrepareScanner()
		tip:SetPlayerBuff(buffIndex)
		local s = ReadScanner()
		speed = speed + s

		i = i + 1
		if i > 32 then break end
	end

	--talents: both the casting speed they grant and whether any of them is the one
	--that makes casting speed shorten damage over time
	for tab = 1, GetNumTalentTabs() do
		for index = 1, GetNumTalents(tab) do
			local _, _, _, _, rank = GetTalentInfo(tab, index)
			if rank and rank > 0 then
				local tip = PrepareScanner()
				tip:SetTalent(tab, index)
				local s, dots = ReadScanner()
				speed = speed + s
				if dots then scales = true end
			end
		end
	end

	lib.castingSpeed = speed / 100
	lib.scalesDots = scales
	lib.dirty = false
end

--Fraction, so 0.06 for 6%. Rescans only when something has invalidated it.
function lib:GetCastingSpeed()
	if lib.dirty then lib:Rescan() end
	return lib.castingSpeed
end

--Whether this character has a talent that makes casting speed shorten DoTs. Without
--one, casting speed does nothing to duration and the base values stand.
function lib:ScalesDots()
	if lib.dirty then lib:Rescan() end
	return lib.scalesDots
end

--Base duration adjusted for the tick speed increase, at the 100% efficiency the
--talent describes. Returns the duration untouched when nothing applies.
function lib:AdjustDuration(duration)
	if not duration or duration <= 0 then return duration end
	if not lib:ScalesDots() then return duration end

	local speed = lib:GetCastingSpeed()
	if speed <= 0 then return duration end

	return duration / (1 + speed)
end

lib:RegisterEvent("PLAYER_ENTERING_WORLD")
lib:RegisterEvent("UNIT_INVENTORY_CHANGED")
lib:RegisterEvent("PLAYER_AURAS_CHANGED")
lib:RegisterEvent("CHARACTER_POINTS_CHANGED")
lib:RegisterEvent("SPELLS_CHANGED")

lib:SetScript("OnEvent", function()
	--only the player's own gear matters; party members fire this too
	if event == "UNIT_INVENTORY_CHANGED" and arg1 and arg1 ~= "player" then return end

	--marked rather than rescanned: buff changes are frequent, and the next reader
	--pays the cost once instead of every event paying it
	lib.dirty = true
end)
