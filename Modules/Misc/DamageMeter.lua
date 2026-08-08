local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, tonumber, type = pairs, tonumber, type
local format, sort, find = string.format, table.sort, string.find
local gsub, strsub, strlen = string.gsub, string.sub, string.len
local tinsert, tremove, getn = table.insert, table.remove, table.getn
--WoW API / Variables
local GetTime = GetTime
local UnitName = UnitName
local UnitExists = UnitExists
local GetNumRaidMembers, GetNumPartyMembers = GetNumRaidMembers, GetNumPartyMembers
local CreateFrame = CreateFrame
local IsShiftKeyDown = IsShiftKeyDown
local GetCVar = GetCVar
local _G = _G

--[[
	Damage and healing accumulator.

	Written from scratch rather than adapted. ShaguDPS carries no licence at all and
	its upstream was archived in June 2026, and Details! is all rights reserved, so
	neither can go into a public, launcher-installable addon. DPSMate is GPL-3 and
	targets 1.12.1, but taking it would oblige this addon to be GPL-3, and OctoUI has
	no licence of its own to make that commitment with yet. What follows owes nothing
	to any of them: the event names and their argument order are facts about the
	client, and are readable from any addon that consumes them.

	The usual way to write a vanilla damage meter is to parse CHAT_MSG_COMBAT_* and
	CHAT_MSG_SPELL_* text against the client's global strings. That is several hundred
	lines, breaks on every locale, cannot tell two mobs of the same name apart, and is
	capped by the combat log's own range. None of it is necessary here. nampower emits
	structured events carrying GUIDs and raw amounts, so this reads numbers instead of
	sentences.

	nampower is strongly preferred but no longer required: without it the meter reads the
	combat log instead, which is worse in every way and is why it is the fallback rather
	than the design. From 4.5.0 onwards registering the event is enough to turn nampower's
	events on -- the NP_Enable*Events CVars are deprecated compatibility toggles and do
	not need setting.

	Which source is in use is decided by nampower's CVars, NOT by whether its events
	registered. RegisterEvent accepts any string on this client without complaint -- an
	event that cannot exist registers happily -- so "did RegisterEvent succeed" answers
	nothing at all. That mistake is what made the fallback unreachable in the first
	version of this file. See InitializeDamageMeter.

	Mind the argument order, it is not consistent between events:
		SPELL_DAMAGE_EVENT_SELF/OTHER (targetGuid, casterGuid, spellId, amount, ...)
		AUTO_ATTACK_SELF/OTHER        (attackerGuid, targetGuid, totalDamage, ...)
		SPELL_HEAL_BY_SELF/OTHER      (targetGuid, casterGuid, spellId, amount, ...)
		DAMAGE_SHIELD_SELF/OTHER      (unitGuid, targetGuid, damage, school)
	Damage and healing put the *target* first; auto attacks and damage shields put the
	*source* first.
]]

local DAMAGE_EVENTS = {"SPELL_DAMAGE_EVENT_SELF", "SPELL_DAMAGE_EVENT_OTHER"}
local SWING_EVENTS = {"AUTO_ATTACK_SELF", "AUTO_ATTACK_OTHER"}
local SHIELD_EVENTS = {"DAMAGE_SHIELD_SELF", "DAMAGE_SHIELD_OTHER"}
local HEAL_EVENTS = {"SPELL_HEAL_BY_SELF", "SPELL_HEAL_BY_OTHER"}

--Optional: only needed to attribute a damage shield to whoever cast it. Registered
--separately so their absence cannot stop the meter working.
local AURA_EVENTS = {"AURA_CAST_ON_SELF", "AURA_CAST_ON_OTHER"}

--Two segments, in the same shape: [guid] = {name, damage, healing, first, last, spells}
--`current` is the fight in progress and is wiped when a new one starts; `overall`
--accumulates until it is reset by hand.
local current, overall = {}, {}
local combatStart, combatEnd
local combatTime = 0

--Finished fights, newest first: { {store, duration, label, ended}, ... }. A segment is
--banked when combat drops, so "the pull before last" stays readable after the next one
--has already overwritten `current` -- which is the whole reason a meter is worth having
--after the fight rather than during it.
--
--Capped, and deliberately low. Every entry holds a full actor table with its per-spell
--breakdown, and this is a 1.12 client where the addon memory a fight costs is real; a
--long raid night would otherwise accumulate hundreds of them for no one to ever read.
local history = {}
local HISTORY_MAX = 10

--Damage the group dealt to each unit during the fight in progress, which is the only
--thing that can name a segment after what was fought. Reset with `current`.
local currentTargets = {}

--Fights this short are a stray proc or a critter, not something anyone wants a row in
--the picker for.
local HISTORY_MIN_DURATION = 4

--GUIDs worth recording: you, your pet, and your group with theirs. The *_OTHER
--events report every bit of damage in range, so without this the meter happily
--credits whoever happens to be killing something nearby -- a stranger outside
--Stormwind turns up above you on your own wand damage.
local tracked = {}

--Pet GUID -> owner GUID. A pet is somebody's damage, not its own line item: for a
--warlock or hunter most of the meter would otherwise sit in a second row under the
--minion's name, and the owner's total would read as a fraction of what they actually
--did. Merging is the default, and matches what every other meter does.
local owners = {}

--Shielded unit -> whoever put the shield there. A damage shield event names only the
--unit wearing it: "You reflect 9 Fire damage" is what the client says, with no
--reference to the imp that applied Fire Shield or the warlock that owns the imp. The
--information simply is not in the event, so it has to come from watching the aura go
--on in the first place.
--
--This is a heuristic and is off by default because of it. It records the last aura a
--tracked unit cast on each target, which is right when the shield is the only thing
--being cast on that unit and wrong the moment a heal or a buff lands afterwards.
--Refining it needs the aura's school or effect type to match against the shield
--event's school -- run /octoui-dps debug and watch what AURA_CAST_ON_* actually
--carries on this server before trying.
local shieldSource = {}

local watcher
local available
local usingCombatLog
local debugging

--Declared up here rather than beside the fallback that fills them: Available and
--MeterSource close over both, and a local declared further down the file would leave
--those two reading a nil global instead.
local logEvents, logPatterns = {}, {}

--Whether the meter has any source of numbers at all -- nampower's events, or failing
--that a combat log the client gave us enough format strings to read. A fallback that
--matched nothing would be a window that stays empty forever, which is worse than
--saying plainly that the meter cannot run here.
local function Available()
	if available then return true end

	return (usingCombatLog and getn(logPatterns) > 0) and true or false
end

--"nampower", "combatlog" or nil, with the two counts the report command needs to say
--how much of the combat log this client actually handed over.
function M:MeterSource()
	if available then return "nampower" end
	if not usingCombatLog then return end

	local events = 0
	for _ in pairs(logEvents) do events = events + 1 end

	return "combatlog", getn(logPatterns), events
end

--SuperWoW returns the GUID as a second value from UnitExists
local function GuidOf(unit)
	local exists, guid = UnitExists(unit)
	if exists and guid then return guid end
end

local function RefreshTracked()
	tracked, owners = {}, {}

	local function add(unit, ownerUnit)
		--The combat log deals in names, never GUIDs, so the fallback parser needs the
		--same roster keyed the other way. Both sets are filled here rather than in two
		--places that could drift apart, and a name key costs nothing when unused.
		local name = UnitName(unit)
		if name and name ~= "" and name ~= "Unknown Entity" then
			tracked[name] = true

			if ownerUnit then
				local ownerName = UnitName(ownerUnit)
				if ownerName and ownerName ~= "" then owners[name] = ownerName end
			end
		end

		local guid = GuidOf(unit)
		if not guid then return end

		tracked[guid] = true

		if ownerUnit then
			local ownerGuid = GuidOf(ownerUnit)
			if ownerGuid then owners[guid] = ownerGuid end
		end
	end

	add("player")
	add("pet", "player")

	--Only the slots that can actually hold somebody. Written as a flat 1..4 and 1..40 it
	--asked about ninety units regardless, eighty of them raid slots that do not exist
	--when solo -- and every one of those is a UnitName plus a UnitExists, which under
	--SuperWoW means resolving a unit token against the object list.
	--
	--This runs on UNIT_PET, which fires as a pet disengages from a target that just died.
	--So the moment an object was being destroyed was also the moment this fired several
	--hundred lookups at it, together with the killing blow's own events. That is the
	--current best explanation for the client deadlocking on a mob dying mid-cast.
	local raid = GetNumRaidMembers()
	if raid > 0 then
		for i = 1, raid do
			add("raid"..i)
			add("raidpet"..i, "raid"..i)
		end
	else
		for i = 1, GetNumPartyMembers() do
			add("party"..i)
			add("partypet"..i, "party"..i)
		end
	end
end

--A GUID is a usable unit token under SuperWoW, so the name usually comes straight
--back. Pets and anything out of range may not resolve, in which case the GUID stands
--in for a name rather than the entry being dropped -- a nameless row is still a real
--source, and it will usually resolve on a later look.
--
--Cached, and unresolved GUIDs are retried on a timer rather than on every event. UnitName
--with a GUID is SuperWoW walking its object list; Actor below re-asked on every single
--damage event for as long as a name had not resolved, which for a mob that never resolves
--is a lookup per event for the whole fight. Doing that while an object is being destroyed
--is the leading theory for the client freezing outright with a mob dying mid-cast, so the
--traffic is worth removing whether or not it turns out to be the cause.
local nameCache, nameRetry = {}, {}
local NAME_RETRY_AFTER = 5

local function ResolveName(guid)
	if not guid then return end

	local cached = nameCache[guid]
	if cached then return cached end

	local now = GetTime()
	if nameRetry[guid] and (now - nameRetry[guid]) < NAME_RETRY_AFTER then
		return guid
	end
	nameRetry[guid] = now

	local name = UnitName(guid)
	if name and name ~= "" and name ~= "Unknown Entity" then
		nameCache[guid] = name
		return name
	end

	return guid
end

local function Actor(store, guid)
	if not guid then return end

	if not store[guid] then
		store[guid] = {
			name = ResolveName(guid),
			damage = 0,
			healing = 0,
			first = GetTime(),
			last = GetTime(),
			spells = {},
		}
	end

	local actor = store[guid]

	--the name may have been a GUID stand-in when we first saw it
	if actor.name == guid then
		actor.name = ResolveName(guid)
	end

	return actor
end

local function Record(guid, spell, amount, isHeal, target)
	amount = tonumber(amount)
	if not (guid and amount and amount > 0) then return end

	--Anything outside the group is somebody else's fight
	if not tracked[guid] then return end

	--Who the group was hitting, so a banked fight can be named after what was fought.
	--Only damage: the target of a heal is a group member, and labelling the pull after
	--whoever was being healed would be worse than not labelling it at all.
	if target and not isHeal then
		currentTargets[target] = (currentTargets[target] or 0) + amount
	end

	--Credit a pet's work to whoever summoned it. The spell key keeps the pet marker so
	--the contribution is still separable once there is a breakdown view to show it.
	--Read straight off the db rather than through MeterDB(), which is declared further
	--down with the window and is not in scope up here.
	local cfg = E.db.general.damageMeter
	if owners[guid] and (not cfg or cfg.mergePets ~= false) then
		spell = spell and ("pet:"..spell) or "pet"
		guid = owners[guid]
	end

	local stores = {current, overall}
	for i = 1, 2 do
		local actor = Actor(stores[i], guid)
		if actor then
			actor.last = GetTime()

			if isHeal then
				actor.healing = actor.healing + amount
			else
				actor.damage = actor.damage + amount
			end

			--per-spell breakdown, keyed by whatever identifier the event carried
			local key = spell or "melee"
			local entry = actor.spells[key]
			if not entry then
				entry = {damage = 0, healing = 0, hits = 0}
				actor.spells[key] = entry
			end

			entry.hits = entry.hits + 1
			if isHeal then
				entry.healing = entry.healing + amount
			else
				entry.damage = entry.damage + amount
			end
		end
	end
end

--[[ combat log fallback ]]--
--
--Used only when nampower's structured events are not on this client. Everything the
--module header says about this way of working still holds -- it reads sentences instead
--of numbers, it cannot tell two mobs of the same name apart, and it is capped by the
--combat log's own range -- so it is the worse source and never runs alongside the good
--one. What it buys is that the meter works at all for somebody without the DLL, which
--is the difference between a feature and a feature only the author can use.
--
--Not a word of English appears below. Every pattern is one of the client's own format
--strings, matched through LibDebuff's cmatch, which reads the captures back in the order
--the *format string* declares them however the locale chooses to print them. That is
--already load-bearing for the debuff timers, so it is the tested path rather than a
--second copy written for here.
--
--Two guards make the uncertainty survivable. A format string this client does not have
--is skipped when the table is built, and an event it has never heard of is dropped by
--the pcall around RegisterEvent -- so a name that turns out to be wrong costs that one
--line of coverage instead of erroring at login. /octoui-dps reports what actually
--registered, which is the only honest way to find out.
--
--All 31 names below were since confirmed present with OctoProbe (`/oprobe strings` and
--`/oprobe events`), so the guards are now belt and braces rather than the load-bearing
--part. The probe also caught the one real error here: see the note on the two
--PERIODICAURADAMAGE constants, whose names read as the opposite of what they mean.

--Candidates. Damage and healing done by the player, their pet, and the group.
local LOG_EVENT_NAMES = {
	"CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_PARTY_HITS",
	"CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS", "CHAT_MSG_COMBAT_PET_HITS",
	"CHAT_MSG_SPELL_SELF_DAMAGE", "CHAT_MSG_SPELL_PARTY_DAMAGE",
	"CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE", "CHAT_MSG_SPELL_PET_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_PARTY_BUFF",
	"CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
	"CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
}

--Resolved on demand: this file loads before the NamePlates module exists.
local function CombatMatch(text, pattern)
	local module = E.GetModule and E:GetModule("NamePlates", true)
	local lib = module and module.LibDebuff
	if not (lib and lib.Match) then return end

	return lib:Match(text, pattern)
end

local playerName

--{ format string name, handler(captures in format-string order) }.
--
--The school-qualified wordings come before the plain ones of the same family. They are
--not actually ambiguous -- "for %d." needs a full stop straight after the digits and
--"for %d %s damage." does not -- but the ordering is what the reader should be able to
--rely on rather than that argument.
local LOG_HANDLERS = {
	--your melee
	{"COMBATHITCRITSCHOOLSELFOTHER", function(target, amount) Record(playerName, "melee", amount, nil, target) end},
	{"COMBATHITSCHOOLSELFOTHER", function(target, amount) Record(playerName, "melee", amount, nil, target) end},
	{"COMBATHITCRITSELFOTHER", function(target, amount) Record(playerName, "melee", amount, nil, target) end},
	{"COMBATHITSELFOTHER", function(target, amount) Record(playerName, "melee", amount, nil, target) end},

	--somebody else's melee; the roster filter in Record drops anyone outside the group
	{"COMBATHITCRITSCHOOLOTHEROTHER", function(source, target, amount) Record(source, "melee", amount, nil, target) end},
	{"COMBATHITSCHOOLOTHEROTHER", function(source, target, amount) Record(source, "melee", amount, nil, target) end},
	{"COMBATHITCRITOTHEROTHER", function(source, target, amount) Record(source, "melee", amount, nil, target) end},
	{"COMBATHITOTHEROTHER", function(source, target, amount) Record(source, "melee", amount, nil, target) end},

	--your spells
	{"SPELLLOGCRITSCHOOLSELFOTHER", function(spell, target, amount) Record(playerName, spell, amount, nil, target) end},
	{"SPELLLOGSCHOOLSELFOTHER", function(spell, target, amount) Record(playerName, spell, amount, nil, target) end},
	{"SPELLLOGCRITSELFOTHER", function(spell, target, amount) Record(playerName, spell, amount, nil, target) end},
	{"SPELLLOGSELFOTHER", function(spell, target, amount) Record(playerName, spell, amount, nil, target) end},

	--somebody else's spells
	{"SPELLLOGCRITSCHOOLOTHEROTHER", function(source, spell, target, amount) Record(source, spell, amount, nil, target) end},
	{"SPELLLOGSCHOOLOTHEROTHER", function(source, spell, target, amount) Record(source, spell, amount, nil, target) end},
	{"SPELLLOGCRITOTHEROTHER", function(source, spell, target, amount) Record(source, spell, amount, nil, target) end},
	{"SPELLLOGOTHEROTHER", function(source, spell, target, amount) Record(source, spell, amount, nil, target) end},

	--damage over time, which the log phrases as the target suffering rather than
	--anyone hitting, and so shares no wording with the above
	--SELFOTHER is "<target> suffers N damage from your <spell>" -- damage you dealt.
	--OTHERSELF is "You suffer N damage from <caster>'s <spell>", which is damage dealt
	--*to* you and has no business in a meter of damage done. They read as though the
	--halves were the other way round, and the first version of this file had them
	--swapped: a warlock's entire DoT contribution went missing while every enemy tick
	--landing on them was credited to them as damage. Confirmed against the client's own
	--strings with /oprobe strings; do not swap them back on the strength of the names.
	{"PERIODICAURADAMAGESELFOTHER", function(target, amount, school, spell) Record(playerName, spell, amount, nil, target) end},
	{"PERIODICAURADAMAGEOTHEROTHER", function(target, amount, school, source, spell) Record(source, spell, amount, nil, target) end},

	--healing
	{"HEALEDCRITSELFSELF", function(spell, amount) Record(playerName, spell, amount, true) end},
	{"HEALEDSELFSELF", function(spell, amount) Record(playerName, spell, amount, true) end},
	{"HEALEDCRITSELFOTHER", function(spell, target, amount) Record(playerName, spell, amount, true) end},
	{"HEALEDSELFOTHER", function(spell, target, amount) Record(playerName, spell, amount, true) end},
	{"HEALEDCRITOTHERSELF", function(source, spell, amount) Record(source, spell, amount, true) end},
	{"HEALEDOTHERSELF", function(source, spell, amount) Record(source, spell, amount, true) end},
	{"HEALEDCRITOTHEROTHER", function(source, spell, target, amount) Record(source, spell, amount, true) end},
	{"HEALEDOTHEROTHER", function(source, spell, target, amount) Record(source, spell, amount, true) end},
}

local function ParseCombatLog(text)
	if not text then return end

	for i = 1, getn(logPatterns) do
		local entry = logPatterns[i]
		local a, b, c, d, e = CombatMatch(text, entry[1])
		if a then
			entry[2](a, b, c, d, e)
			return --one line is one event; a second match would double count it
		end
	end
end

--Returns how many format strings and events this client actually gave us, so the
--report command can say whether the fallback has anything to work with.
local function SetupCombatLogFallback(frame)
	playerName = UnitName("player")

	for i = 1, getn(LOG_HANDLERS) do
		local name = LOG_HANDLERS[i][1]
		local pattern = _G[name]
		if type(pattern) == "string" then
			tinsert(logPatterns, {pattern, LOG_HANDLERS[i][2], name})
		end
	end

	for i = 1, getn(LOG_EVENT_NAMES) do
		local name = LOG_EVENT_NAMES[i]
		if pcall(frame.RegisterEvent, frame, name) then
			logEvents[name] = true
		end
	end

	local events = 0
	for _ in pairs(logEvents) do events = events + 1 end

	return getn(logPatterns), events
end

--Names the fight after whatever took the most damage from the group. The first version
--of this read the *sources* table instead, which contains only group members, so every
--banked fight was labelled with the top damage dealer's own name -- "Carcer (18s)" tells
--you nothing about which pull it was. Falls back to the top damage dealer only when
--nothing was hit at all, which in practice means a pure healing segment.
local function SegmentLabel(store)
	local best, bestDamage
	for guid, damage in pairs(currentTargets) do
		if damage > (bestDamage or 0) then
			best, bestDamage = guid, damage
		end
	end

	if best then return ResolveName(best) end

	for _, actor in pairs(store) do
		if actor.damage > (bestDamage or 0) then
			best, bestDamage = actor.name, actor.damage
		end
	end

	return best
end

--Moves the finished fight into history. Called when combat drops, before anything
--overwrites `current`.
local function BankSegment(duration)
	if duration < HISTORY_MIN_DURATION then return end

	--nothing happened; a fight nobody in the group contributed to is not worth a row
	local any
	for _, actor in pairs(current) do
		if actor.damage > 0 or actor.healing > 0 then any = true break end
	end
	if not any then return end

	--The store is handed over rather than copied, and `current` is replaced with a fresh
	--table at the start of the next fight, so the two never share state.
	tinsert(history, 1, {
		store = current,
		duration = duration,
		label = SegmentLabel(current),
		ended = GetTime(),
	})

	--tremove, never `history[getn(history)] = nil`. In Lua 5.0 table.insert maintains a
	--hidden `n` field and table.getn returns it when present, but assigning nil to a slot
	--does not decrement it -- so that idiom re-reads the same length for ever and never
	--terminates. It froze the client at 100% of one core on the eleventh banked fight of
	--a session, which is why it always struck well into an evening and always as combat
	--ended: BankSegment runs on PLAYER_REGEN_ENABLED. table.remove decrements `n`.
	while getn(history) > HISTORY_MAX do
		tremove(history)
	end
end

local function OnEvent()
	--Checked before anything else: these only ever fire in fallback mode, and every
	--other branch below is testing for an event name that cannot be one of them.
	if logEvents[event] then
		ParseCombatLog(arg1)
		return
	end

	if event == "PLAYER_REGEN_DISABLED" then
		--A new fight wipes the current segment but never the overall one
		current, currentTargets = {}, {}
		combatStart, combatEnd = GetTime(), nil
		return
	elseif event == "PLAYER_REGEN_ENABLED" then
		combatEnd = GetTime()

		--Banked so the overall figure is time spent fighting, not wall clock since
		--login and not the gap between first and last hit
		if combatStart then
			combatTime = combatTime + (combatEnd - combatStart)
			BankSegment(combatEnd - combatStart)
		end
		return
	elseif event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED"
		or event == "RAID_ROSTER_UPDATE" or event == "UNIT_PET" then
		RefreshTracked()

		return
	end

	--Raw args, names resolved, for working out who the client credits something to.
	--Attribution questions -- damage shields, guardians, anything applied by one unit
	--and carried by another -- are answerable in ten seconds here and not at all by
	--reading code, because only the client knows what it puts in arg1.
	if debugging then
		E:Print(format("%s | arg1 %s (%s) | arg2 %s (%s) | arg3 %s | arg4 %s",
			event,
			tostring(arg1), tostring(arg1 and UnitName(arg1) or "?"),
			tostring(arg2), tostring(arg2 and UnitName(arg2) or "?"),
			tostring(arg3), tostring(arg4)))
	end

	--Damage and healing name the target first, the source second
	if event == "SPELL_DAMAGE_EVENT_SELF" or event == "SPELL_DAMAGE_EVENT_OTHER" then
		Record(arg2, arg3, arg4, nil, arg1)
	elseif event == "SPELL_HEAL_BY_SELF" or event == "SPELL_HEAL_BY_OTHER" then
		Record(arg2, arg3, arg4, true)

	--Swings and damage shields name the source first
	elseif event == "AUTO_ATTACK_SELF" or event == "AUTO_ATTACK_OTHER" then
		Record(arg1, "melee", arg3, nil, arg2)
	elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
		--(spellId, caster, target, effect, effectname)
		if arg2 and arg3 and tracked[arg2] then
			shieldSource[arg3] = arg2
		end

	elseif event == "DAMAGE_SHIELD_SELF" or event == "DAMAGE_SHIELD_OTHER" then
		local source = arg1

		--Optionally hand it to whoever applied the shield instead of whoever is
		--wearing it. Off by default: the game credits the wearer, every other meter
		--credits the wearer, and a number nobody else can reproduce starts arguments
		--rather than settling them.
		local cfg = E.db.general.damageMeter
		if cfg and cfg.shieldToCaster and shieldSource[arg1] then
			source = shieldSource[arg1]
		end

		Record(source, "shield", arg3, nil, arg2)
	end
end

--[[ spell names ]]--
--
--nampower's events carry a numeric spell ID, so the breakdown was rendering rows like
--"11711  468  20%" -- arithmetic about something the reader cannot identify. The combat
--log fallback carries real names already, so only the nampower path needs this.
--
--SuperWoW's SpellInfo is what turns an ID into a name. Guarded, because it is absent
--without SuperWoW, and cached, because the window redraws four times a second and this
--would otherwise be a lookup per spell per frame.
--
--OFF while a run of crashes is being bisected, and this is the leading suspect. The
--argument that it was safe -- "CastBar.lua has called SpellInfo for ages" -- does not
--hold: CastBar passes ids from UNIT_CASTEVENT, which are *cast* ids, while this passes
--ids from SPELL_DAMAGE_EVENT_*, which include damage-over-time ticks, pet abilities and
--damage shields. That is a different id space, and handing a C function an id it was
--never written to expect is an out-of-bounds read away from taking the process down with
--no Lua error and no dump -- exactly the signature being chased. pcall does not help;
--it catches Lua errors, not access violations.
--
--Set true to put names back once the client has been shown to be stable without them.
local RESOLVE_SPELL_NAMES = true

local spellNames = {}

local function SpellName(id)
	if not RESOLVE_SPELL_NAMES then return false end
	if spellNames[id] ~= nil then return spellNames[id] end

	local name
	if SpellInfo then
		local ok, resolved = pcall(SpellInfo, id)
		if ok and type(resolved) == "string" and resolved ~= "" then
			name = resolved
		end
	end

	--false rather than nil: a lookup that failed once must not be retried every frame
	spellNames[id] = name or false

	return spellNames[id]
end

--A key is "melee", "shield", a numeric spell id, or any of those behind the "pet:"
--marker Record adds. Falls back to the raw key, so an id SpellInfo cannot resolve still
--shows something rather than an empty row.
local function DisplaySpell(key)
	local prefix, bare = "", key

	local _, _, rest = find(key, "^pet:(.*)$")
	if rest then
		prefix = L["Pet"]..": "
		bare = rest
	end

	if bare == "melee" then return prefix..L["Melee"] end
	if bare == "shield" then return prefix..L["Damage Shield"] end

	local id = tonumber(bare)

	return prefix..((id and SpellName(id)) or bare)
end

--A segment name is "current", "overall", or "fight:N" for the Nth entry in history --
--1 being the most recent. Returns the store and, for a banked fight, its fixed duration.
local function Segment(name)
	if name == "current" then return current end
	if name == "overall" or not name then return overall end

	local _, _, index = find(name, "^fight:(%d+)$")
	local entry = index and history[tonumber(index)]
	if entry then return entry.store, entry.duration end

	--a fight that has since dropped off the end of the history
	return overall
end

--The banked fights, newest first, for the picker: { {segment, label, duration}, ... }
function M:MeterHistory()
	local list = {}

	for i = 1, getn(history) do
		tinsert(list, {
			segment = "fight:"..i,
			label = history[i].label or UNKNOWN or "?",
			duration = history[i].duration,
			ended = history[i].ended,
		})
	end

	return list
end

--Per-spell breakdown for one actor in one segment, sorted, as
--{ {name, damage, healing, hits, share}, ... } plus the actor's own total.
--`share` is the fraction of that actor's total the spell accounts for, which is the
--number the detail view is actually for -- the raw amounts are already on the row.
function M:MeterSpells(segment, guid, mode)
	local store = Segment(segment)
	local actor = store and store[guid]
	if not actor then return {}, 0 end

	local healing = (mode == "healing")
	local total = healing and actor.healing or actor.damage
	local list, byName = {}, {}

	--Merged on the resolved name rather than the stored key. Ranks of one spell are
	--separate ids and would otherwise be separate rows, three lines all reading "Shadow
	--Bolt" and none of them the real total. The ids stay distinct in the record; this is
	--presentation only.
	for key, entry in pairs(actor.spells) do
		local value = healing and entry.healing or entry.damage
		if value > 0 then
			local name = DisplaySpell(key)
			local row = byName[name]

			if not row then
				row = {name = name, damage = 0, healing = 0, hits = 0, value = 0}
				byName[name] = row
				tinsert(list, row)
			end

			row.damage = row.damage + entry.damage
			row.healing = row.healing + entry.healing
			row.hits = row.hits + entry.hits
			row.value = row.value + value
		end
	end

	for i = 1, getn(list) do
		list[i].share = (total > 0) and (list[i].value / total) or 0
	end

	sort(list, function(a, b) return a.value > b.value end)

	return list, total
end

--Seconds the segment has been running. Falls back to the spread of the entries
--themselves when combat never formally started, which is how a dummy parse looks.
function M:MeterDuration(segment)
	if segment == "current" then
		if not combatStart then return 0 end
		return (combatEnd or GetTime()) - combatStart
	end

	--a banked fight's length is fixed and was recorded when it ended
	local _, banked = Segment(segment)
	if banked then return banked end

	--Time actually spent in combat, plus the fight in progress
	local total = combatTime
	if combatStart and not combatEnd then
		total = total + (GetTime() - combatStart)
	end

	if total > 0 then return total end

	--Nothing banked yet: fall back to the spread of the entries themselves, which is
	--all a target dummy parse outside combat can offer
	local first, last
	for _, actor in pairs(overall) do
		if not first or actor.first < first then first = actor.first end
		if not last or actor.last > last then last = actor.last end
	end

	return (first and last and last > first) and (last - first) or 0
end

--Sorted list of actors for a segment: { {name, damage, healing, dps}, ... }
function M:MeterData(segment)
	local store = Segment(segment)
	local duration = M:MeterDuration(segment)
	local rows = {}

	for guid, actor in pairs(store) do
		tinsert(rows, {
			guid = guid,
			name = actor.name or guid,
			damage = actor.damage,
			healing = actor.healing,
			--Per-actor active time would flatter anyone who joined late; the segment
			--length is what every other meter means by DPS
			dps = (duration > 0) and (actor.damage / duration) or 0,
			hps = (duration > 0) and (actor.healing / duration) or 0,
		})
	end

	sort(rows, function(a, b) return a.damage > b.damage end)

	return rows, duration
end

--Noisy by design; every damage event in range prints a line. Meant for a few seconds
--of deliberate testing, not for leaving on.
function M:ToggleMeterDebug()
	debugging = not debugging

	return debugging and true or false
end

function M:ResetMeter()
	current, overall, history = {}, {}, {}
	combatStart, combatEnd, combatTime = nil, nil, 0

	--a banked fight the user just cleared must not stay selected, or the window shows a
	--segment that no longer exists and silently falls back to overall
	local db = E.db.general.damageMeter
	if db and db.segment and find(db.segment, "^fight:") then
		db.segment = "current"
	end
end

function M:InitializeDamageMeter()
	watcher = CreateFrame("Frame", "OctoUI_DamageMeter", E.UIParent)
	watcher:SetScript("OnEvent", OnEvent)

	--This used to decide whether nampower was present by pcall'ing RegisterEvent on its
	--events and treating a failure as "not here". That test does not work: RegisterEvent
	--on this client accepts *any* string without complaint, proven by registering an
	--event that cannot exist (OctoProbe's canary). So the pcall never failed, `available`
	--was true on every machine, and the combat-log fallback below was unreachable code --
	--a feature that could not run for the people it was written for.
	--
	--The CVars are the honest test. nampower registers them as the DLL loads, long before
	--any addon runs, and GetCVar answers nil for them when the DLL is not in the session
	--at all; /octoui-queue exists to report exactly that. The Lua API is a weaker signal
	--on its own, because these DLLs register their Lua functions *after* addons load, so
	--a check this early can see nil for a DLL that is very much present -- it is only
	--consulted as a second opinion, where a positive is still conclusive.
	available = (GetCVar and GetCVar("NP_SpellQueueWindowMs") and true)
		or (type(_G.QueueSpellByName) == "function")
		or nil

	if available then
		--Still pcall'd, purely so a future client that *does* validate cannot error here
		local groups = {DAMAGE_EVENTS, SWING_EVENTS, SHIELD_EVENTS, HEAL_EVENTS}
		for i = 1, getn(groups) do
			local group = groups[i]
			for j = 1, getn(group) do
				pcall(watcher.RegisterEvent, watcher, group[j])
			end
		end
	end

	if available then
		--Best effort; the meter works without them, only shield attribution needs them
		for i = 1, getn(AURA_EVENTS) do
			pcall(watcher.RegisterEvent, watcher, AURA_EVENTS[i])
		end
	else
		--No nampower. Fall back to reading the combat log, which is worse in every way
		--but is the difference between the meter existing for other people and not.
		--Never both: the two sources describe the same hits and would double every
		--number, which is why this is an else and not a second registration pass.
		usingCombatLog = true
		SetupCombatLogFallback(watcher)
	end

	watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
	watcher:RegisterEvent("PLAYER_REGEN_ENABLED")

	--Who counts as "us" changes with the group and with pets being summoned
	watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
	watcher:RegisterEvent("PARTY_MEMBERS_CHANGED")
	watcher:RegisterEvent("RAID_ROSTER_UPDATE")
	watcher:RegisterEvent("UNIT_PET")

	RefreshTracked()
	M:BuildMeterWindow()
end


--[[ window ]]--

--Skinned, anchored and moved the same way every other OctoUI element is, so it lines
--up with the threat meter rather than sitting at whatever offset its own drag code
--felt like. Position lives in E.db.movers like everything else: shift-drag moves the
--mover, /moveui moves the mover, and the reset button puts the mover back.
local window, rows, lastUpdate = nil, {}, 0

--Set while the per-spell breakdown is on screen: { segment, guid, name }. The segment
--is pinned at the moment of the click rather than read live, so switching the window to
--another fight while a breakdown is open cannot quietly show somebody else's numbers
--under the name that was clicked.
local detail

local MODES = {damage = "damage", healing = "healing"}

local function MeterDB()
	return E.db.general.damageMeter or P.general.damageMeter
end

--Full figures with thousands separators, not "3.8k".
--
--Abbreviating threw away the number people actually want to read: 3800 and 3849 both
--render as "3.8k", and a damage meter exists to show you the number. Big numbers are also
--most of the point of one.
local function Short(value)
	local text = format("%d", value)

	--Insert a separator every three digits from the right. gsub's second return is the
	--replacement count, which is what ends the loop -- Lua 5.0 has no other way to know
	--a pattern stopped matching.
	local count
	repeat
		text, count = gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
	until count == 0

	return text
end

--Shift-drag has to keep working with the mouse over a row, and a row that enables the
--mouse takes the drag away from the window underneath it. Both are wired to these, so
--there is one implementation of "a drag anywhere on this window moves the mover".
local function StartWindowDrag()
	if not IsShiftKeyDown() then return end

	local mover = _G["DamageMeterMover"]
	if mover then mover:StartMoving() end
end

local function StopWindowDrag()
	local mover = _G["DamageMeterMover"]
	if not mover then return end

	mover:StopMovingOrSizing()

	local x, y, point = E:CalculateMoverPoints(mover)
	mover:ClearAllPoints()
	E:Point(mover, point, E.UIParent, point, x, y)
	E:SaveMoverPosition("DamageMeterMover")
end

local function CreateRow(index)
	local row = CreateFrame("StatusBar", nil, window)
	E:Height(row, MeterDB().height)
	row:SetMinMaxValues(0, 1)
	row:SetValue(0)
	row:SetStatusBarTexture(E.media.normTex)
	E:CreateBackdrop(row, "Transparent")

	row.label = row:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(row.label, nil, MeterDB().height - 4, "OUTLINE")
	E:Point(row.label, "LEFT", row, "LEFT", 3, 0)
	row.label:SetJustifyH("LEFT")

	row.amount = row:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(row.amount, nil, MeterDB().height - 4, "OUTLINE")
	E:Point(row.amount, "RIGHT", row, "RIGHT", -3, 0)
	row.amount:SetJustifyH("RIGHT")

	if index == 1 then
		E:Point(row, "TOPLEFT", window, "TOPLEFT", 2, -20)
		E:Point(row, "TOPRIGHT", window, "TOPRIGHT", -2, -20)
	else
		E:Point(row, "TOPLEFT", rows[index - 1], "BOTTOMLEFT", 0, -1)
		E:Point(row, "TOPRIGHT", rows[index - 1], "BOTTOMRIGHT", 0, -1)
	end

	--Click a source to see what it was made of, click anything in the breakdown to come
	--back out. Right-click backs out from either, so there is always a way back that
	--does not depend on having noticed the "<" in the title.
	row:EnableMouse(true)
	row:RegisterForDrag("LeftButton")
	row:SetScript("OnDragStart", StartWindowDrag)
	row:SetScript("OnDragStop", StopWindowDrag)
	row:SetScript("OnMouseUp", function()
		if IsShiftKeyDown() then return end --that was a drag, not a click

		if detail or arg1 == "RightButton" then
			detail = nil
		elseif this.guid then
			local db = MeterDB()
			detail = {
				segment = db.segment or "current",
				guid = this.guid,
				name = this.actorName,
			}
		end

		M:UpdateMeterWindow()
	end)

	row:Hide()

	return row
end

--LONG NAMES RUN INTO THE BUTTONS.
--
--The title FontString is anchored TOPLEFT with no right bound, and the segment button is a
--fixed 50 pixels with its label centred and unclipped. A fight named after a long mob
--overflows both: "Deadwood Shaman" ran straight through the Damage button and rendered as
--"Oeadwood ShamanDamage". Reported 2026-08-08.
--
--Measured with GetStringWidth rather than cut at a character count, so it stays correct if
--the font or the size changes -- and so it trims exactly as far as it has to, no further.
local function Fit(fontString, text, maxWidth)
	fontString:SetText(text)
	if maxWidth <= 0 or fontString:GetStringWidth() <= maxWidth then return end

	local trimmed = text
	while strlen(trimmed) > 1 do
		trimmed = strsub(trimmed, 1, strlen(trimmed) - 1)
		fontString:SetText(trimmed.."..")
		if fontString:GetStringWidth() <= maxWidth then return end
	end
end

--Trims `label` until the WHOLE composed line fits, then hands the fitted label back so the
--caller can re-compose it with colour codes.
--
--Colours are applied afterwards on purpose: they do not render, so measuring them would
--overstate the width, and trimming a string with an escape in it can cut the escape in half
--and spill raw |cff into the title.
local function FitLabel(fontString, compose, label, maxWidth)
	fontString:SetText(compose(label))
	if maxWidth <= 0 or fontString:GetStringWidth() <= maxWidth then return label end

	local trimmed = label
	while strlen(trimmed) > 1 do
		trimmed = strsub(trimmed, 1, strlen(trimmed) - 1)
		fontString:SetText(compose(trimmed..".."))
		if fontString:GetStringWidth() <= maxWidth then return trimmed..".." end
	end

	return label
end

--How much room the title has before the first button. Read off the frames themselves rather
--than summing the widths, so it stays right if a button is resized or the window is.
local function TitleRoom()
	if not (window and window.segment) then return 0 end

	local left, right = window:GetLeft(), window.segment:GetLeft()
	if not (left and right) then return 0 end

	return right - left - 10
end

--The segment button is 50 wide; this leaves a little breathing room inside its border.
local SEGMENT_TEXT_WIDTH = 46

local function TitleButton(text, width, point, relativeTo, relativePoint, x)
	local button = CreateFrame("Button", nil, window)
	E:Width(button, width)
	E:Height(button, 14)
	E:Point(button, point, relativeTo, relativePoint, x, 0)
	E:SetTemplate(button, "Transparent")

	button.text = button:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(button.text, nil, 10, "OUTLINE")
	E:Point(button.text, "CENTER", 0, 0)
	button.text:SetText(text)

	button:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 1, 1) end)
	button:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)

	return button
end

--Draws one page of bars. `entries` is already sorted and already the right shape,
--which is what lets the source list and the per-spell breakdown share every pixel of
--layout code instead of growing a second copy that drifts.
--Each entry: { label, right, value, guid }.
local function RenderRows(db, entries)
	--Everything is scaled against the top row, which is what makes a bar chart
	--readable at a glance; an absolute scale would leave every bar stubby on trash
	local top = 0
	for i = 1, getn(entries) do
		if entries[i].value > top then top = entries[i].value end
	end

	local shown = 0
	for i = 1, db.bars do
		local row = rows[i]
		local entry = entries[i]

		if entry and entry.value > 0 then
			shown = shown + 1
			row:SetValue((top > 0) and (entry.value / top) or 0)

			local color = E.media.rgbvaluecolor
			row:SetStatusBarColor(color[1], color[2], color[3])

			row.label:SetText(format("%d. %s", i, entry.label))
			row.amount:SetText(entry.right)
			row.guid = entry.guid
			--kept unprefixed for the detail title; the label carries a rank number
			row.actorName = entry.label
			row:Show()
		else
			row.guid = nil
			row:Hide()
		end
	end

	--Collapse to the rows actually in use rather than leaving dead space. The frame is
	--anchored by its bottom edge, so this grows the top upwards and the window never
	--reaches further down the screen than where it was placed.
	--
	--The trailing 2 is padding UNDER the last row, so an empty meter must not carry it --
	--otherwise the window keeps a sliver of dead space below the title bar and stops sitting
	--flush against whatever it was lined up with. Empty is exactly the title bar, nothing more.
	local height = 22
	if shown > 0 then height = height + (shown * (db.height + 1)) + 2 end

	E:Height(window, height)
end

--What the segment button and the title call the segment being shown.
local function SegmentName(segment)
	if segment == "overall" then return L["Overall"] end
	if segment == "current" or not segment then return L["Current"] end

	local _, _, index = find(segment, "^fight:(%d+)$")
	local list = M:MeterHistory()
	local entry = index and list[tonumber(index)]

	return entry and entry.label or L["Current"]
end

function M:UpdateMeterWindow()
	if not window or not window:IsShown() then return end

	local db = MeterDB()
	local segment = db.segment or "current"
	local mode = db.mode or MODES.damage
	local healing = (mode == MODES.healing)
	local modeName = healing and L["Healing"] or L["Damage"]

	--Per-spell breakdown for one source. The data has been recorded since the meter was
	--written; this is the view that finally reads it.
	if detail then
		local spells, total = M:MeterSpells(detail.segment, detail.guid, mode)
		local entries = {}

		for i = 1, getn(spells) do
			local spell = spells[i]
			tinsert(entries, {
				label = spell.name,
				--share and hit count, which is what a breakdown is read for; the raw
				--amount alone is already implied by the bar next to it
				right = format("%s  |cff999999%.0f%%  %d|r", Short(spell.value),
					spell.share * 100, spell.hits),
				value = spell.value,
			})
		end

		local fitted = FitLabel(window.title,
			function(name) return format("< %s  %s %s", name, modeName, Short(total)) end,
			detail.name, TitleRoom())

		window.title:SetText(format("|cff999999<|r %s  |cff999999%s %s|r",
			fitted, modeName, Short(total)))
		RenderRows(db, entries)

		return
	end

	local data, duration = M:MeterData(segment)
	local entries = {}

	for i = 1, getn(data) do
		local actor = data[i]
		tinsert(entries, {
			label = actor.name,
			right = format("%s  |cff999999%.0f|r",
				Short(healing and actor.healing or actor.damage),
				healing and actor.hps or actor.dps),
			value = healing and actor.healing or actor.damage,
			guid = actor.guid,
		})
	end

	local fittedSegment = FitLabel(window.title,
		function(label) return format("%s  %s %.0fs", modeName, label, duration) end,
		SegmentName(segment), TitleRoom())

	window.title:SetText(format("%s  |cff999999%s %.0fs|r",
		modeName, fittedSegment, duration))
	RenderRows(db, entries)
end

local function OnUpdate()
	lastUpdate = lastUpdate + (arg1 or 0)
	if lastUpdate < 0.25 then return end

	lastUpdate = 0
	M:UpdateMeterWindow()
end

function M:ToggleMeterWindow()
	if not window then return end

	if window:IsShown() then
		window:Hide()
	else
		window:Show()
		M:UpdateMeterWindow()
	end
end

function M:BuildMeterWindow()
	if window then return end

	local db = MeterDB()

	window = CreateFrame("Frame", "OctoUI_DamageMeterWindow", E.UIParent)
	E:Width(window, db.width)
	E:Height(window, 60)
	E:SetTemplate(window, "Transparent")
	--Anchored by its BOTTOM edge, not its centre, so the list grows *upwards* as rows
	--fill in. That matters wherever it is parked low on the screen: a centre anchor
	--expands equally in both directions and the bottom rows walk off the bottom of the
	--display. Pinning the bottom means the fixed edge is the one nearest the screen
	--edge and every new row goes the safe way.
	--
	--The position itself is where ShaguDPS sat, taken from its own saved config rather
	--than guessed -- it stores the window centre, so this is that centre converted to
	--the bottom-left corner. Only a default; the mover owns it once anything moves it.
	--Sit ON the bottom panel rather than a hand-picked distance up from the screen edge.
	--The panel is 22 tall anchored at -1, so its top edge is 21; the old default of 30 left a
	--9 pixel gap that collapsing the window could never close, because the gap was under the
	--window rather than in it. Anchoring to the panel means the number cannot drift out of
	--agreement with it either.
	--
	--Falls back to the old offset when the panel does not exist, which is the case while it
	--is switched off in the general options.
	local panel = _G["ElvUI_BottomPanel"]
	if panel then
		E:Point(window, "BOTTOMLEFT", panel, "TOPLEFT", 429, 0)
	else
		E:Point(window, "BOTTOMLEFT", E.UIParent, "BOTTOMLEFT", 428, 21)
	end
	window:SetFrameStrata("LOW")

	window.title = window:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(window.title, nil, 11, "OUTLINE")
	E:Point(window.title, "TOPLEFT", window, "TOPLEFT", 4, -5)
	window.title:SetJustifyH("LEFT")

	--"R" on a damage meter means reset the DATA -- that is what it means on every meter
	--anyone has used, and it was wired to reset the window POSITION instead. Reported
	--2026-08-08 as "the R button didn't reset the data when clicked", which is exactly right.
	--
	--Position reset is still worth having and has nowhere else to live, so it moves to the
	--right button. Both are named in a tooltip, because a lone "R" cannot say which is which.
	window.reset = TitleButton("R", 16, "TOPRIGHT", window, "TOPRIGHT", -3)
	window.reset:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	window.reset:SetScript("OnClick", function()
		if arg1 == "RightButton" then
			M:ResetMeterPosition()
			return
		end

		M:ResetMeter()
		detail = nil
		M:UpdateMeterWindow()
		E:Print(L["Damage Meter"]..": data reset.")
	end)

	window.reset:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
		GameTooltip:AddLine(L["Damage Meter"])
		GameTooltip:AddLine(L["METER_RESET_TOOLTIP"], 1, 1, 1)
		GameTooltip:Show()
	end)
	window.reset:SetScript("OnLeave", function()
		E:SetTemplate(this, "Transparent")
		GameTooltip:Hide()
	end)

	window.mode = TitleButton(L["Damage"], 46, "TOPRIGHT", window.reset, "TOPLEFT", -2)
	window.mode:SetScript("OnClick", function()
		local cfg = MeterDB()
		cfg.mode = (cfg.mode == MODES.healing) and MODES.damage or MODES.healing
		this.text:SetText((cfg.mode == MODES.healing) and L["Healing"] or L["Damage"])
		M:UpdateMeterWindow()
	end)

	--Cycles current -> overall -> each banked fight, newest first, and back round. A
	--dropdown would be the obvious thing, but this window is 50 pixels of title bar and
	--the list is usually two or three entries long; cycling costs no chrome at all.
	--Leaving a breakdown open across a segment change would show numbers from a fight
	--the user is no longer looking at, so it closes.
	window.segment = TitleButton(L["Current"], 50, "TOPRIGHT", window.mode, "TOPLEFT", -2)
	window.segment:SetScript("OnClick", function()
		local cfg = MeterDB()
		local order = {"current", "overall"}
		local past = M:MeterHistory()
		for i = 1, getn(past) do
			tinsert(order, past[i].segment)
		end

		local at = 1
		for i = 1, getn(order) do
			if order[i] == cfg.segment then at = i break end
		end

		cfg.segment = order[at + 1] or order[1]
		detail = nil
		Fit(this.text, SegmentName(cfg.segment), SEGMENT_TEXT_WIDTH)
		M:UpdateMeterWindow()
	end)

	window.mode.text:SetText((db.mode == MODES.healing) and L["Healing"] or L["Damage"])
	--Fitted to the button, not just set on it: the segment label is a fight name, so it is
	--the one piece of header text with no bound on its length.
	Fit(window.segment.text, SegmentName(db.segment), SEGMENT_TEXT_WIDTH)

	for i = 1, db.bars do
		rows[i] = CreateRow(i)
	end

	--Straight to this meter's own options rather than making anyone hunt for them
	window.options = TitleButton("O", 16, "TOPRIGHT", window.segment, "TOPLEFT", -2)
	window.options:SetScript("OnClick", function()
		E:ToggleConfig("general")
	end)

	--The mover owns the position. Anchor first: CreateMover reads the current point as
	--its default, and that default is what the reset button goes back to.
	E:CreateMover(window, "DamageMeterMover", L["Damage Meter"], nil, nil, nil, "ALL,GENERAL")

	--Shift-drag moves the mover rather than the frame, so a drag here and a drag in
	--/moveui write the same E.db.movers entry instead of two positions fighting. The
	--rows carry the same two handlers, since a row with the mouse enabled would
	--otherwise swallow every drag that started over it.
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", StartWindowDrag)
	window:SetScript("OnDragStop", StopWindowDrag)

	window:SetScript("OnUpdate", OnUpdate)

	if db.enable == false then
		window:Hide()
	end
end

function M:ResetMeterPosition()
	if E.CreatedMovers and E.CreatedMovers["DamageMeterMover"] then
		E:ResetMovers(L["Damage Meter"])
		E:Print(L["Damage Meter"]..": position reset.")
	end
end

M.MeterAvailable = Available
