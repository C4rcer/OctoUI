local E, L, V, P, G = unpack(ElvUI)

--[[
	Character stats the 1.12 paperdoll does not show.

	Two different problems, and it matters which is which:

	  * Some stats the client *will* tell you -- attack power, resistances, the melee
	    crit percentage -- through ordinary API. Read those, never scan for them.
	  * The rest exist only as English sentences on your gear, buffs and talents.
	    Spell power, spell hit, casting speed and mp5 have no API on this client at
	    all, so the only way to know them is to read the same tooltips you read.

	Everything matched below is the *client's own* tooltip text -- game data, not any
	addon's work.

	Prior art, with thanks: BetterCharacterStats solves this same problem on this same
	client, and its existence is what showed the approach was viable at all. None of
	its code is used here. It carries no licence -- its history begins with "Reupload
	of a lost addon", so even its own origin is unattributable, and thirteen authors
	have contributed since. Credit therefore to Lexie, Spit, Mats391, pepopo978,
	MarcelineVQ and the other contributors, and to whoever wrote the original that was
	lost. The debt here is to the idea, not the source.

	One scan fills every stat, because opening 19 item tooltips is the expensive part
	and doing it once per stat would be daft. Marked dirty on the events that can
	change a stat, rescanned on the next read.
]]

local pairs, tonumber, type = pairs, tonumber, type
local find, lower, gsub = string.find, string.lower, string.gsub

local CreateFrame = CreateFrame
local GetInventoryItemLink = GetInventoryItemLink
local GetNumTalentTabs, GetNumTalents, GetTalentInfo = GetNumTalentTabs, GetNumTalents, GetTalentInfo
local GetPlayerBuff = GetPlayerBuff

local Stats = {}
E.Stats = Stats

Stats.values = {}
Stats.dirty = true

--Tooltip wording -> stat key. Lower-cased before matching, so patterns are too.
--A stat with several wordings simply gets several entries. Order matters within a
--single line: the first match wins, so the more specific wording comes first.
local PATTERNS = {
	--Two genuinely different stats on this server, kept apart rather than summed.
	--"haste" is the general kind that speeds up attacks *and* casting; "castingSpeed"
	--is spell-only. Both raise casting speed, so both feed the DoT scaling, but a
	--paperdoll row must show them separately or it misreports what your gear does.
	--The combined wordings must precede the bare ones: they share a prefix and would
	--otherwise match the narrower pattern and be filed as spell-only.
	--
	--UNVERIFIED: only the talent wording below has been confirmed against a live
	--character. Every gear and buff wording here is inferred from how the client
	--phrases these lines elsewhere, and none has been seen matching a real item. If a
	--haste item reads as 0%, its exact tooltip line is the fix -- one entry, no logic.
	{"increases your attack and casting speed by (%d+)%%", "haste"},
	{"increases attack and casting speed by (%d+)%%", "haste"},
	{"increases casting and attack speed by (%d+)%%", "haste"},
	{"increases attack and spell casting speed by (%d+)%%", "haste"},
	{"attack and casting speed increased by (%d+)%%", "haste"},
	{"^%+(%d+)%% haste", "haste"},

	--Talents word this as "the casting speed of your <school> spells by N%", so the
	--middle has to be open. It is spec-limited rather than global -- fine for the DoT
	--timers, since a warlock's DoTs are exactly the spells it names, but a paperdoll
	--row must not present it as an across-the-board figure.
	{"increases the casting speed of your .- by (%d+)%%", "castingSpeed"},
	{"increases your spell casting speed by (%d+)%%", "castingSpeed"},
	{"increases your casting speed by (%d+)%%", "castingSpeed"},
	{"increases casting speed by (%d+)%%", "castingSpeed"},
	{"casting speed increased by (%d+)%%", "castingSpeed"},
	{"spell casting speed by (%d+)%%", "castingSpeed"},

	--spell power. The school-specific lines are tracked separately as well as in the
	--total, because a fire spell does not benefit from shadow damage gear.
	{"increases damage and healing done by magical spells and effects by up to (%d+)", "spellPower"},
	{"increases damage done by magical spells and effects by up to (%d+)", "spellPower"},
	{"increases healing done by magical spells and effects by up to (%d+)", "healingPower"},
	{"increases healing done by spells and effects by up to (%d+)", "healingPower"},
	{"increases damage done by arcane spells and effects by up to (%d+)", "spellPowerArcane"},
	{"increases damage done by fire spells and effects by up to (%d+)", "spellPowerFire"},
	{"increases damage done by frost spells and effects by up to (%d+)", "spellPowerFrost"},
	{"increases damage done by holy spells and effects by up to (%d+)", "spellPowerHoly"},
	{"increases damage done by nature spells and effects by up to (%d+)", "spellPowerNature"},
	{"increases damage done by shadow spells and effects by up to (%d+)", "spellPowerShadow"},

	--hit and crit
	{"improves your chance to hit with spells by (%d+)%%", "spellHit"},
	{"increases your chance to hit with spells by (%d+)%%", "spellHit"},
	{"improves your chance to get a critical strike with spells by (%d+)%%", "spellCrit"},
	{"increases your critical strike chance with spells by (%d+)%%", "spellCrit"},
	{"improves your chance to hit by (%d+)%%", "meleeHit"},
	{"increases your chance to hit by (%d+)%%", "meleeHit"},
	{"improves your chance to get a critical strike by (%d+)%%", "meleeCrit"},

	--regen
	{"restores (%d+) mana per 5 sec", "mp5"},
	{"restores (%d+) mana every 5 seconds", "mp5"},
	{"^%+(%d+) mana every 5 sec", "mp5"},
	{"allows (%d+)%% of your mana regeneration to continue while casting", "manaWhileCasting"},

	--penetration
	{"decreases the magical resistances of your spell targets by (%d+)", "spellPen"},
	{"your attacks ignore (%d+) of the target's armor", "armorPen"},
}

--A talent whose wording says casting speed shortens damage over time. OctoWoW adds
--these; vanilla has nothing like it. Detected by effect rather than by a per-class
--spell list, so any class with an equivalent talent is picked up without one.
local DOT_SCALING = {"tick speed", "reducing their duration"}

local scanner, lines
local function PrepareScanner()
	if not scanner then
		scanner = CreateFrame("GameTooltip", "OctoUI_StatScanner", nil, "GameTooltipTemplate")
		lines = {}
		for i = 1, 40 do
			lines[i] = _G["OctoUI_StatScannerTextLeft"..i]
		end
	end

	scanner:SetOwner(E.UIParent, "ANCHOR_NONE")
	scanner:ClearLines()

	return scanner
end

--Accumulates every match on the tooltip currently loaded into the scanner.
local function ReadScanner(into)
	for i = 1, scanner:NumLines() do
		local fs = lines[i]
		local text = fs and fs:GetText()
		if text then
			text = lower(text)

			for _, entry in pairs(PATTERNS) do
				local _, _, value = find(text, entry[1])
				if value then
					local key = entry[2]
					into[key] = (into[key] or 0) + (tonumber(value) or 0)
					break --one stat per line; shared prefixes would otherwise double count
				end
			end

			for _, phrase in pairs(DOT_SCALING) do
				if find(text, phrase) then into.scalesDots = true break end
			end
		end
	end
end

function Stats:Refresh()
	local values = {}

	--equipped gear
	for slot = 1, 19 do
		if GetInventoryItemLink("player", slot) then
			PrepareScanner():SetInventoryItem("player", slot)
			ReadScanner(values)
		end
	end

	--active buffs. 1.12 addresses these through GetPlayerBuff, not a plain 1..n loop
	local i = 0
	while i <= 32 do
		local buffIndex = GetPlayerBuff(i, "HELPFUL")
		if not buffIndex or buffIndex < 0 then break end

		PrepareScanner():SetPlayerBuff(buffIndex)
		ReadScanner(values)
		i = i + 1
	end

	--talents that are actually taken
	for tab = 1, GetNumTalentTabs() do
		for index = 1, GetNumTalents(tab) do
			local _, _, _, _, rank = GetTalentInfo(tab, index)
			if rank and rank > 0 then
				PrepareScanner():SetTalent(tab, index)
				ReadScanner(values)
			end
		end
	end

	--school-specific spell power stacks on top of the generic kind
	local generic = values.spellPower or 0
	for _, school in pairs({"Arcane", "Fire", "Frost", "Holy", "Nature", "Shadow"}) do
		local key = "spellPower"..school
		values[key] = (values[key] or 0) + generic
	end

	Stats.values = values
	Stats.dirty = false
end

--Raw value for a stat key, 0 when absent. Percentages are whole numbers, so a 6%
--casting speed increase reads 6, not 0.06.
function Stats:Get(key)
	if Stats.dirty then Stats:Refresh() end
	return Stats.values[key] or 0
end

function Stats:ScalesDots()
	if Stats.dirty then Stats:Refresh() end
	return Stats.values.scalesDots and true or false
end

function Stats:Invalidate()
	Stats.dirty = true
end

local watcher = CreateFrame("Frame", "OctoUI_StatWatcher")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("UNIT_INVENTORY_CHANGED")
watcher:RegisterEvent("PLAYER_AURAS_CHANGED")
watcher:RegisterEvent("CHARACTER_POINTS_CHANGED")
watcher:RegisterEvent("SPELLS_CHANGED")

watcher:SetScript("OnEvent", function()
	--party members fire the inventory event too; only ours can change our stats
	if event == "UNIT_INVENTORY_CHANGED" and arg1 and arg1 ~= "player" then return end

	--marked, not rescanned: buffs change constantly and a full pass is 19 item
	--tooltips plus every buff plus the talent trees. The next reader pays it once.
	Stats:Invalidate()
end)
