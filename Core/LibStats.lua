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

local pairs, tonumber, type, abs = pairs, tonumber, type, math.abs
local find, lower, gsub = string.find, string.lower, string.gsub

local CreateFrame = CreateFrame
local GetInventoryItemLink = GetInventoryItemLink
local GetNumTalentTabs, GetNumTalents, GetTalentInfo = GetNumTalentTabs, GetNumTalents, GetTalentInfo
local GetPlayerBuff = GetPlayerBuff
local UnitStat, UnitLevel, UnitClass = UnitStat, UnitLevel, UnitClass

local Stats = {}
E.Stats = Stats

Stats.values = {}
--Keys whose number is a real total -- read from an API, or computed from the attribute
--formula underneath the scan -- and keys with no source on this client at all. Between
--them the panel can tell a total from a gear-only partial, and both from a stat it
--simply cannot see.
Stats.complete = {}
Stats.unavailable = {}
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

	--Enchants. An enchantment is a line on the item's own tooltip, so the gear pass
	--above already reads it -- but it is phrased as a bare "+N Stat" rather than as one
	--of the sentences an item's own stats use, which is why none of it was being picked
	--up. Anchored to the start of the line so a sentence that merely contains the words
	--cannot match. Longest wording first where two share a prefix.
	--
	--UNVERIFIED, all of them, exactly like the haste block above: these are the wordings
	--this client is expected to use, not ones seen matching a live enchant. An enchant
	--that reads as 0 is one line here, no logic.
	{"^%+(%d+) spell damage and healing", "spellPower"},
	{"^%+(%d+) healing and spell damage", "spellPower"},
	{"^%+(%d+) damage and healing spells", "spellPower"},
	{"^%+(%d+) spell damage", "spellPower"},
	{"^%+(%d+) healing spells", "healingPower"},
	{"^%+(%d+) spell penetration", "spellPen"},
	{"^%+(%d+)%% spell hit", "spellHit"},
	{"^%+(%d+)%% hit", "meleeHit"},
	{"^%+(%d+)%% crit", "meleeCrit"},

	--A shield states its block value on its own line, the same way it states its armour.
	--There is no API for this on 1.12 -- confirmed in game, both GetShieldBlock and
	--GetBlockValue are absent, which is what left the row reading "--" -- so the item's
	--own tooltip is the only source there is. Anchored, or the "Block" in a trinket's
	--prose would match.
	{"^(%d+) block$", "blockValue"},
}

--A talent whose wording says casting speed shortens damage over time. OctoWoW adds
--these; vanilla has nothing like it. Detected by effect rather than by a per-class
--spell list, so any class with an equivalent talent is picked up without one.
local DOT_SCALING = {"tick speed", "reducing their duration"}

--[[ API-sourced stats ]]--
--
--Anything the client will answer directly is read, never scanned for: a tooltip pass
--sees only the gear half of a stat, while the API knows the whole number including the
--base every character has before a single item is worn.
--
--Every entry names the global it needs and is only called once that global has been
--confirmed to exist. This client is a moving target, so an absent one has to mean "this
--stat cannot be shown" rather than an error at login; Refresh records the misses in
--Stats.unavailable and the panel prints "--".
--
--Measured with OctoProbe (octoui-dev/OctoProbe, `/oprobe stats`) rather than guessed at.
--PRESENT: UnitAttackPower, UnitRangedAttackPower, UnitDefense, UnitArmor, UnitStat,
--UnitResistance, GetDodgeChance, GetParryChance, GetBlockChance.
--ABSENT: GetCritChance, GetSpellCritChance, GetRangedCritChance, GetShieldBlock,
--GetBlockValue, GetHitModifier, GetManaRegen, GetSpellBonusDamage, GetSpellBonusHealing,
--GetSpellPenetration, GetCombatRating, GetAttackPowerForStat.
--
--Two things follow from that list and are worth stating outright, because both are the
--reason this file is shaped the way it is. There is no API for spell power or healing
--power at all, so the tooltip scan is not a shortcut but the only route. And every crit
--getter is missing, which is why spell crit is computed from Intellect below.
--
--Return shapes, also measured: UnitStat gives base, effective, positive, negative and
--the *second* is the one to use -- Int read 143, 143, 60, 0, so the effective figure
--already contains the +60 and adding the buff again would double it. UnitResistance
--likewise answers base, total, positive, negative, and shadow read 0, 1, 1, 0.
--
--UnitXP_SP3 was checked first, as the handoff asked: it exposes nothing of the sort.
--Its UnitXP() dispatcher only answers "target", "notify", "version", "FPScap" and a
--set of camera and nameplate categories. There is no stat surface there to use.
--
--Resistances are here because they were asked for, but the 1.12 paperdoll already
--shows five of them beside the character model, so their rows default to off in
--Settings/Profile.lua rather than duplicating what is on screen already.
local RESISTANCES = {
	{"resistArcane", 6}, {"resistFire", 2}, {"resistFrost", 4},
	{"resistHoly", 1}, {"resistNature", 3}, {"resistShadow", 5},
}

--[[ stats derived from an attribute ]]--
--
--Spell crit and mana regen have no API on this client -- GetSpellCritChance is absent,
--confirmed in game -- and a tooltip scan can only ever see the gear, buff and talent
--part. Both also have a base every character carries from an attribute before a single
--item is worn, and without it the rows could only ever say "--", which is no use to
--anyone gearing for them. A warlock chasing Improved Shadow Bolt uptime needs a number.
--
--The constants below are the *server core's* formulas, not a rule of thumb: vmangos is
--the emulator lineage this server's own core descends from, so these are the arithmetic
--the server is actually running, and they scale with level rather than assuming 60.
--They are game facts and free to use; no code was taken from anywhere to get them, and
--BetterCharacterStats -- which reads the same public constants -- carries no licence and
--could not have been borrowed from even if it had been useful to.
--
--Verify rather than trust, all the same. This is a Vanilla+ server that has already
--changed one formula this addon depends on (casting speed shortening damage over time),
--so it can change these. ObservedSpellCrit below counts real casts out of the combat
--log and the row's tooltip shows measured against calculated. If they disagree over a
--decent sample the measured one is right, and the fix is one number in this table.

--Spell crit %: base + Intellect / (a + b * level).
local SPELL_CRIT = {
	MAGE    = {3.7,  14.77, 0.65},
	WARLOCK = {3.18, 11.30, 0.82},
	PRIEST  = {2.97, 10.03, 0.82},
	DRUID   = {3.33, 12.41, 0.79},
	SHAMAN  = {3.54, 11.51, 0.80},
	PALADIN = {3.7,  14.77, 0.65},
}

--Mana regen: Spirit / divisor + flat, per two-second tick. Converted to a per-5-second
--figure below, because that is what the row is called and what gear says on the tin --
--mixing the two units silently would be wrong by a factor of 2.5.
local SPIRIT_REGEN = {
	DRUID = {5, 15}, HUNTER = {5, 15}, MAGE = {4, 12.5}, PALADIN = {5, 15},
	PRIEST = {4, 12.5}, SHAMAN = {5, 17}, WARLOCK = {5, 15},
}

local TICKS_PER_5_SECONDS = 2.5

local API = {}

--Stat keys the tooltip scan can reach on its own. A key in here is never reported as
--unavailable, however its API turns out: melee crit and spell crit have both a reader
--and scan patterns, and losing the gear figure because the client happens not to have
--GetSpellCritChance would be a worse answer than the partial one.
local SCANNED = {}
for i = 1, getn(PATTERNS) do
	SCANNED[PATTERNS[i][2]] = true
end

--`global` is either one name or a list of alternatives, and `fn` is only ever reached
--once at least one of them is a function -- so a reader may call its API plainly.
local function DefineAPI(key, global, fn)
	API[getn(API) + 1] = {key, type(global) == "table" and global or {global}, fn}
end

local function HaveAPI(names)
	for i = 1, getn(names) do
		if type(_G[names[i]]) == "function" then return true end
	end
end

--base plus buffs; the negative half already arrives negative
DefineAPI("attackPower", "UnitAttackPower", function()
	local base, pos, neg = UnitAttackPower("player")
	return (base or 0) + (pos or 0) + (neg or 0)
end)

DefineAPI("rangedAttackPower", "UnitRangedAttackPower", function()
	local base, pos, neg = UnitRangedAttackPower("player")
	return (base or 0) + (pos or 0) + (neg or 0)
end)

DefineAPI("defense", "UnitDefense", function()
	local base, modifier = UnitDefense("player")
	return (base or 0) + (modifier or 0)
end)

DefineAPI("dodge", "GetDodgeChance", function() return GetDodgeChance() end)
DefineAPI("parry", "GetParryChance", function() return GetParryChance() end)
DefineAPI("block", "GetBlockChance", function() return GetBlockChance() end)

--Neither spelling exists on this client -- checked in game, the row read "--" -- so
--block value comes from the shield's own tooltip instead, see PATTERNS. The reader is
--left in place because it costs nothing and would take over automatically, with its
--whole-number accuracy, on a client that does have one.
DefineAPI("blockValue", {"GetShieldBlock", "GetBlockValue"}, function()
	if type(GetShieldBlock) == "function" then return GetShieldBlock() end
	return GetBlockValue()
end)

--Melee crit and spell crit also have scan patterns, and the scan can only ever see the
--gear part. When these APIs exist their number is the real total, so Refresh marks the
--key complete and the panel drops the "+" prefix and the partial-stat tooltip on its
--own -- no row definition has to change for that to happen.
DefineAPI("meleeCrit", "GetCritChance", function() return GetCritChance() end)
DefineAPI("spellCrit", "GetSpellCritChance", function() return GetSpellCritChance() end)

for i = 1, getn(RESISTANCES) do
	local key, index = RESISTANCES[i][1], RESISTANCES[i][2]
	DefineAPI(key, "UnitResistance", function()
		--second return is the total including buffs; first is the base alone
		local base, total = UnitResistance("player", index)
		return total or base or 0
	end)
end

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

--A set item's tooltip lists *every* bonus the set has, not only the ones earned. The
--unearned ones are drawn grey and the earned ones green, and until this check existed
--the scan counted all of them -- so wearing one piece of an eight-piece set credited the
--character with the full eight-piece spell power. Colour is the only thing that
--separates them; the text is identical.
--
--Grey is the one colour worth testing for. Item stat lines are white, "Equip:" and
--earned set bonuses are green, flavour text is gold; the other grey lines on an item
--tooltip are level and class requirements, which match no pattern here and so cost
--nothing to skip.
local function IsUnearnedLine(fs)
	if not fs.GetTextColor then return end

	local r, g, b = fs:GetTextColor()
	if not (r and g and b) then return end

	return abs(r - 0.5) < 0.1 and abs(g - 0.5) < 0.1 and abs(b - 0.5) < 0.1
end

--Accumulates every match on the tooltip currently loaded into the scanner.
local function ReadScanner(into)
	for i = 1, scanner:NumLines() do
		local fs = lines[i]
		local text = fs and not IsUnearnedLine(fs) and fs:GetText()
		if text then
			text = lower(text)

			--Indexed, not `pairs`. The whole "first match wins, so the more specific
			--wording comes first" rule that PATTERNS is written around is a statement
			--about order, and pairs makes no promise of one -- the ordering held by luck
			--of the hash, and adding an entry could have silently rearranged it.
			for p = 1, getn(PATTERNS) do
				local entry = PATTERNS[p]
				local _, _, value = find(text, entry[1])
				if value then
					local key = entry[2]
					into[key] = (into[key] or 0) + (tonumber(value) or 0)
					break --one stat per line; shared prefixes would otherwise double count
				end
			end

			for d = 1, getn(DOT_SCALING) do
				if find(text, DOT_SCALING[d]) then into.scalesDots = true break end
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

	--API values last, and they overwrite: where a stat has both a reader and scan
	--patterns, the API knows the base the scan cannot see, so its number is the whole
	--truth and the scanned one is a subset of it.
	--
	--pcall'd on top of the existence check. A function being present is not a promise
	--that it takes these arguments on this client, and one bad call here would take the
	--whole panel down rather than costing a single row.
	local complete, unavailable = {}, {}
	for i = 1, getn(API) do
		local key, globals, read = API[i][1], API[i][2], API[i][3]

		local got = false
		if HaveAPI(globals) then
			local ok, value = pcall(read)
			if ok and type(value) == "number" then
				values[key] = value
				complete[key] = true
				got = true
			end
		end

		--only a stat with no other source counts as unavailable; see SCANNED
		if not (got or SCANNED[key]) then
			unavailable[key] = true
		end
	end

	--Attribute-derived bases last, and they *add* rather than overwrite: what the scan
	--found is the gear and talent part, and this is the part underneath it. A class with
	--no entry -- a warrior has no spell crit worth the row -- simply keeps the scanned
	--figure and stays marked partial.
	local _, class = UnitClass("player")
	local level = UnitLevel("player") or 1

	local crit = class and SPELL_CRIT[class]
	if crit then
		local _, intellect = UnitStat("player", 4)
		if intellect then
			--kept separately as well as folded in: ImpliedIntPerCrit has to subtract the
			--gear and talent part back out to work out what the attribute is really worth
			values.spellCritGear = values.spellCrit or 0
			values.spellCrit = crit[1] + (intellect / (crit[2] + crit[3] * level)) + values.spellCritGear
			complete.spellCrit = true
		end
	end

	local regen = class and SPIRIT_REGEN[class]
	if regen then
		local _, spirit = UnitStat("player", 5)
		if spirit then
			local perTick = (spirit / regen[1]) + regen[2]
			values.mp5 = (perTick * TICKS_PER_5_SECONDS) + (values.mp5 or 0)
			complete.mp5 = true
		end
	end

	Stats.values = values
	Stats.complete = complete
	Stats.unavailable = unavailable
	Stats.dirty = false
end

--Raw value for a stat key, 0 when absent. Percentages are whole numbers, so a 6%
--casting speed increase reads 6, not 0.06.
function Stats:Get(key)
	if Stats.dirty then Stats:Refresh() end
	return Stats.values[key] or 0
end

--False only for a stat whose API this client does not have. A scanned stat is always
--available -- finding nothing on the gear is an answer, not a failure.
function Stats:Available(key)
	if Stats.dirty then Stats:Refresh() end
	return not Stats.unavailable[key]
end

--True when the number is a real total rather than the gear-and-buff part of one. Lets a
--row that is marked partial stop apologising for itself the moment its API turns up.
function Stats:IsComplete(key)
	if Stats.dirty then Stats:Refresh() end
	return Stats.complete[key] and true or false
end

function Stats:ScalesDots()
	if Stats.dirty then Stats:Refresh() end
	return Stats.values.scalesDots and true or false
end

function Stats:Invalidate()
	Stats.dirty = true
end

--[[ measured spell crit ]]--
--
--The check on the formula above. Counts the player's own direct spell damage out of the
--combat log, crits against the rest, and reports the rate actually observed -- which is
--server truth rather than an assumption about what the server is running.
--
--Direct damage only. Damage over time cannot crit in vanilla and arrives on a different
--event, so it is excluded by simply not listening for it; counting DoT ticks as
--non-crits would drag the measured rate toward zero and make a correct formula look
--broken.
--
--Matched through LibDebuff's cmatch against the client's own format strings, the same
--way the damage meter's fallback reads the log, so no English appears here and a locale
--that reorders its arguments still lands.
local observedCrits, observedHits = 0, 0

--{ format string name, is it the crit wording }
local CRIT_LOG = {
	{"SPELLLOGCRITSCHOOLSELFOTHER", true},
	{"SPELLLOGSCHOOLSELFOTHER", false},
	{"SPELLLOGCRITSELFOTHER", true},
	{"SPELLLOGSELFOTHER", false},
}

--Percentage and sample size, or nil when nothing has been seen yet. A rate off two
--casts is noise, so the caller is handed the count and can say so.
function Stats:ObservedSpellCrit()
	local total = observedCrits + observedHits
	if total == 0 then return end

	return (observedCrits / total) * 100, total
end

function Stats:ResetObservedSpellCrit()
	observedCrits, observedHits = 0, 0
end

--The Intellect-per-crit divisor the measured rate implies, given the base and the gear
--and talent crit we already know about. This is the number to put in SPELL_CRIT if the
--measured rate and the calculated one keep disagreeing.
function Stats:ImpliedIntPerCrit()
	local measured, samples = Stats:ObservedSpellCrit()
	if not measured then return end

	local _, class = UnitClass("player")
	local crit = class and SPELL_CRIT[class]
	if not crit then return end

	local _, intellect = UnitStat("player", 4)
	if not (intellect and intellect > 0) then return end

	--whatever the measured rate is left with once the flat base and the crit we can
	--actually see on gear and talents are taken out; the rest is the attribute's doing
	local fromInt = measured - crit[1] - (Stats:Get("spellCritGear") or 0)
	if fromInt <= 0 then return end

	return intellect / fromInt, samples
end

local critWatcher = CreateFrame("Frame", "OctoUI_SpellCritWatch")
critWatcher:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
critWatcher:SetScript("OnEvent", function()
	if not arg1 then return end

	--resolved per event rather than cached: this file loads before NamePlates exists
	local module = E.GetModule and E:GetModule("NamePlates", true)
	local lib = module and module.LibDebuff
	if not (lib and lib.Match) then return end

	for i = 1, getn(CRIT_LOG) do
		local pattern = _G[CRIT_LOG[i][1]]
		if pattern and lib:Match(arg1, pattern) then
			if CRIT_LOG[i][2] then
				observedCrits = observedCrits + 1
			else
				observedHits = observedHits + 1
			end

			return --one line is one cast; the crit wordings are checked first
		end
	end
end)

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
