local E, L, V, P, G = unpack(ElvUI)
local mod = E:GetModule("NamePlates")

--[[
	Debuff duration tracking for 1.12.

	UnitDebuff here returns texture, stacks and dispel type -- no duration and no
	caster -- so a timer has to be reconstructed. The combat log says *when* a debuff
	landed, Settings\DebuffDurations\<locale>.lua says how long that spell lasts, and
	the two together give a countdown. Durations that vary at runtime (combo points,
	talents) are adjusted in GetDuration.

	Ported from ShaguPlates' libdebuff by Eric Mauser (Shagu), MIT licensed; the full
	notice sits at the top of the generated duration files. The logic is his: the
	pending-spell handshake in particular (queue the spell on cast, commit it when the
	"is afflicted by" message arrives, drop it on a miss/resist/immune) is what keeps
	a timer from starting on a debuff that never actually applied.

	Keyed by unit name and level, because the combat log on this client only ever
	gives names -- and additionally by GUID whenever we can tell which mob a name
	referred to, so two mobs of the same name do not share one countdown. See
	AddEffect and GetTimeLeft.

	Durations here are the unhasted base values. OctoWoW scales damage over time with
	casting speed, which vanilla does not, so our own casts run through LibHaste; see
	GetDuration.
]]

local pairs, tonumber, type = pairs, tonumber, type
local getn, tinsert, tremove = table.getn, table.insert, table.remove
local format, gsub, gfind, find = string.format, string.gsub, string.gfind, string.find
local floor = math.floor
local GetTime = GetTime
local GetComboPoints, GetTalentInfo = GetComboPoints, GetTalentInfo
local UnitName, UnitLevel, UnitClass = UnitName, UnitLevel, UnitClass
local GetSpellName, GetNumSpellTabs, GetSpellTabInfo = GetSpellName, GetNumSpellTabs, GetSpellTabInfo

local lib = CreateFrame("Frame", "OctoUI_LibDebuff")
mod.LibDebuff = lib

lib.objects = {}
lib.pending = {}

--[[
	EFFECTS SOMEBODY ELSE HAS ALSO CAST ON A MOB, keyed by GUID then effect name.

	The store below holds one entry per (mob, level, effect) and has no room for a caster
	dimension -- and it could not use one anyway, because the display side cannot tell two
	icons apart: UnitDebuff returns texture, stacks and dispel type, and a tooltip scan gives
	a name that is identical for both. With two warlocks on one mob there are two Curse of
	Agony icons and nothing on this client distinguishes them.

	So ownership is not always decidable, and the honest thing is to say so rather than pick.
	UNIT_CASTEVENT fires for every unit in range with the caster's GUID, so we can at least
	know WHEN it is undecidable: if anyone else has cast the same tracked effect at this mob,
	the effect is contested and GetTimeLeft stops reporting "player" for it.

	The consumer sees a nil caster, which reads as "not known to be mine" -- so the border
	falls back to its dispel-type colour instead of claiming someone else's DoT is yours.
	Reported 2026-08-09: every warlock's Agony drew green.

	THAT VETO WAS TOO STRONG, and reported as such 2026-08-12: with a second warlock on the
	mob it took the player's own DoT away from them entirely, which is the opposite of the
	problem it was written for. Two corrections, both of them Cursive-Raid's design:

	  * A cast of YOUR OWN is definitive and outranks the veto while it is still running.
	    Cursive keeps playerOwnedCasts[targetGuid][spell] from UNIT_CASTEVENT and nobody
	    else's cast clears it; lib.owncasts below is the same record. You dotted this mob,
	    so one of these icons is certainly yours.

	  * The veto EXPIRES. It used to be `true` forever -- one foreign Agony and that mob's
	    Agony could never read as yours again for the rest of the session, long after their
	    DoT had gone. It now holds the time their cast can no longer be up by.

	What cannot be fixed is the attribution itself: with two Agony icons and nothing on this
	client to tell them apart, either both read as yours or neither does. Claiming both is
	the error worth making, because the alternative loses the timer the player actually
	needs.
]]
lib.contested = {}

--[[
	YOUR OWN CASTS, per mob and effect, held until the moment they can no longer be up.

	This is Cursive-Raid's playerOwnedCasts. Written from AddEffect rather than from the
	event handler so that every route to "the player cast this" feeds it -- UNIT_CASTEVENT,
	the pending-cast commit, a channel and a paladin's judgement all go through there, and a
	record kept in one of those places only would be a record that disagrees with itself.
]]
lib.owncasts = {}

function lib:NoteOwnCast(guid, effect, duration)
	if not guid or not effect then return end

	if not lib.owncasts[guid] then lib.owncasts[guid] = {} end
	lib.owncasts[guid][effect] = GetTime() + (duration or 0)
end

--True while a cast of the player's own could still be on this mob. Expired entries are
--dropped as they are found, so nothing has to sweep the table.
function lib:OwnCastLive(guid, effect)
	local store = guid and effect and lib.owncasts[guid]
	local expires = store and store[effect]
	if not expires then return false end

	if expires < GetTime() then
		store[effect] = nil
		return false
	end

	return true
end

--[[
	WHICH ICON IS YOURS, when the mob carries two of the same debuff.

	Reported 2026-08-12: with a second warlock on the mob, both Agony icons drew green.
	Both resolve to one store entry -- same name, same texture, same dispel type -- so
	whatever that entry says gets said twice.

	Two things narrow it down.

	SuperWoW gives UnitDebuff a FOURTH RETURN, the spell id, which this addon has never
	read. Cursive-Raid reads it everywhere. Ranks are separate ids, so when the other
	warlock is not casting the identical rank the icons are told apart exactly: an icon
	whose id is not the id we cast is definitely not ours.

	When the ids match there is nothing left to distinguish them, so the claim goes to the
	first icon that asks and the rest are refused. One green border is wrong half the time;
	two are wrong always, and the timer under the green one is right either way.

	Claims expire on their own at the end of the frame -- GetTime does not advance within
	one -- so no caller has to remember to reset anything, and re-asking for the SAME icon
	inside one frame is answered consistently. `tag` separates consumers because nameplates
	and unit frames number their icons differently.
]]
lib.ownspell = {}
local claims = {}

function lib:NoteOwnSpell(guid, effect, spellID)
	if not (guid and effect and spellID) then return end

	if not lib.ownspell[guid] then lib.ownspell[guid] = {} end
	lib.ownspell[guid][effect] = spellID
end

function lib:ClaimOwn(tag, guid, effect, index, spellID)
	--An effect with no name cannot be reasoned about at all.
	if not effect or effect == "" then return true end

	--NO GUID IS NOT A YES. This used to `return true` whenever the GUID was
	--missing, which handed the owned border to EVERY icon carrying the effect --
	--from the one function whose whole purpose is granting it to exactly one.
	--
	--That is also the worst moment to be permissive, because the other two
	--safeguards are gated on the same GUID and fail with it: GetTimeLeft's
	--`Contested` veto is skipped, and the store lookup falls back to the name
	--table that every mob of that name shares. Three checks, one missing value,
	--all three off -- which is precisely "every other warlock's Corruption is
	--mine".
	--
	--Falling back to a name-less key still limits the claim to one icon per
	--effect per frame. It cannot hide a dot the old code would have shown
	--EXCEPT where it was showing several at once, which is the tradeoff the
	--GUID path already makes and documents: one border wrong half the time
	--beats two wrong always.
	local mine = guid and lib.ownspell[guid] and lib.ownspell[guid][effect]
	if mine and spellID and mine ~= spellID then return false end

	local key = tag..(guid or "noguid")..effect
	local now = GetTime()
	local held = claims[key]

	if held and held.t == now then
		return held.index == index
	end

	held = held or {}
	held.t, held.index = now, index
	claims[key] = held

	return true
end

--Someone else's cast, still recent enough to be up. Same self-cleaning shape.
function lib:Contested(guid, effect)
	local store = guid and effect and lib.contested[guid]
	local expires = store and store[effect]
	if not expires then return false end

	if expires < GetTime() then
		store[effect] = nil
		return false
	end

	return true
end

local lastspell
--The entry written by SPELLCAST_CHANNEL_START, held so CHANNEL_STOP can end that exact
--effect rather than whatever was written most recently.
local channelEntry
--The last spell known to have been channelled. Survives between channels on purpose; see
--SPELLCAST_CHANNEL_START.
local channelEffect
local _, playerClass = UnitClass("player")

local function Durations() return E.DebuffDurations and E.DebuffDurations["debuffs"] end
local function DynDebuffs() return E.DebuffDurations and E.DebuffDurations["dyndebuffs"] end
local function Judgements() return E.DebuffDurations and E.DebuffDurations["judgements"] end

--[[ pattern helpers ]]--
--Blizzard's combat log globals are format strings ("%s is afflicted by %s."), and
--some locales reorder the arguments ("%2$s ... %1$s"). Turn one into a Lua pattern,
--then read which capture ended up where, so a reordered locale still returns the
--unit first and the effect second.
local sanitizeCache = {}
local function SanitizePattern(pattern)
	if not pattern then return end
	if sanitizeCache[pattern] then return sanitizeCache[pattern] end

	local ret = pattern
	ret = gsub(ret, "([%+%-%*%(%)%?%[%]%^])", "%%%1") --escape magic characters
	ret = gsub(ret, "%d%$", "") --remove capture indexes
	ret = gsub(ret, "(%%%a)", "%(%1+%)") --catch all characters
	ret = gsub(ret, "%%s%+", ".+") --convert all %s to .+
	ret = gsub(ret, "%(.%+%)%(%%d%+%)", "%(.-%)%(%%d%+%)") --numbers before strings
	sanitizeCache[pattern] = ret

	return ret
end

--A miss is cached as `false`, which is the whole point of the rewrite. Previously a
--pattern whose gfind yielded nothing left the cache entry nil, and `if not
--captureCache[pattern]` then re-ran both gsubs and the gfind on every subsequent call --
--for ever, since the result never changes. That is not a small waste: cmatch is on the
--combat-log path this library uses to track debuff durations, so it runs on the order of
--every damage message in a fight, and the work it was repeating is string rewriting plus
--an iterator over a generated pattern.
--
--Found while looking for something capable of freezing the client, which is exactly the
--kind of load that does it. Now runs once per pattern, ever.
local captureCache = {}
local function GetCaptures(pattern)
	local cached = captureCache[pattern]

	if cached == nil then
		cached = false
		for a, b, c, d, e in gfind(gsub(pattern, "%((.+)%)", "%1"), gsub(pattern, "%d%$", "%%(.-)$")) do
			cached = {a, b, c, d, e}
		end
		captureCache[pattern] = cached
	end

	if not cached then return end

	return cached[1], cached[2], cached[3], cached[4], cached[5]
end

local function cmatch(str, pattern)
	if not str or not pattern then return end

	local a, b, c, d, e = GetCaptures(pattern)
	local _, _, va, vb, vc, vd, ve = find(str, SanitizePattern(pattern))

	local ra = e == 1 and ve or d == 1 and vd or c == 1 and vc or b == 1 and vb or va
	local rb = e == 2 and ve or d == 2 and vd or c == 2 and vc or a == 2 and va or vb
	local rc = e == 3 and ve or d == 3 and vd or a == 3 and va or b == 3 and vb or vc
	local rd = e == 4 and ve or a == 4 and va or c == 4 and vc or b == 4 and vb or vd
	local re = a == 5 and va or d == 5 and vd or c == 5 and vc or b == 5 and vb or ve

	return ra, rb, rc, rd, re
end

--Public: the damage meter's combat-log fallback needs exactly this, and writing a
--second copy of the capture-reordering logic would mean two things to keep right when
--a locale turns out to order its arguments differently. Takes a raw combat log line and
--one of Blizzard's format strings, returns the captures in the order the *format string*
--declares them, whatever order the locale prints them in.
function lib:Match(str, pattern)
	return cmatch(str, pattern)
end

--[[ durations ]]--
function lib:GetMaxRank(effect)
	local durations = Durations()
	if not (durations and durations[effect]) then return 0 end

	local max = 0
	for id in pairs(durations[effect]) do
		if id > max then max = id end
	end

	return max
end

--`hasted` scales the result by the player's casting speed. OctoWoW makes casting
--speed shorten damage-over-time effects, which vanilla does not, so this applies to
--our own casts only -- we have no way to know another caster's haste.
function lib:GetDuration(effect, rank, hasted)
	local durations = Durations()
	if not (durations and durations[effect]) then return 0 end

	rank = rank and tonumber((gsub(rank, RANK or "Rank ", ""))) or 0
	rank = durations[effect][rank] and rank or lib:GetMaxRank(effect)

	local duration = durations[effect][rank]
	if not duration then return 0 end

	--durations that are not fixed at cast time
	local dyn = DynDebuffs()
	if dyn then
		local count
		if effect == dyn["Rupture"] then
			duration = duration + GetComboPoints() * 2
		elseif effect == dyn["Kidney Shot"] then
			duration = duration + GetComboPoints()
		elseif effect == dyn["Demoralizing Shout"] then
			_, _, _, _, count = GetTalentInfo(2, 1) --Booming Voice, 10% each
			if count and count > 0 then duration = duration + (duration / 100 * (count * 10)) end
		elseif effect == dyn["Shadow Word: Pain"] then
			_, _, _, _, count = GetTalentInfo(3, 4) --Improved SW:P, +3s each
			if count and count > 0 then duration = duration + count * 3 end
		elseif effect == dyn["Frostbolt"] then
			_, _, _, _, count = GetTalentInfo(3, 7) --Permafrost, +1s each
			if count and count > 0 then duration = duration + count end
		elseif effect == dyn["Gouge"] then
			_, _, _, _, count = GetTalentInfo(2, 1) --Improved Gouge, +.5s each
			if count and count > 0 then duration = duration + (count * 0.5) end
		end
	end

	if hasted and mod.LibHaste then
		duration = mod.LibHaste:AdjustDuration(duration)
	end

	return duration
end

--[[ effect store ]]--
--`guid` is optional and additive. The combat log only ever gives names, so the store
--has to be keyed by name to work at all -- but a name is not unique, and two mobs of
--the same name and level would otherwise share one countdown. Whenever we can tell
--which mob it actually was (it was our target), the same entry is filed under its
--GUID as well, and GetTimeLeft prefers that key. Same table both ways, so they cannot
--drift apart. A second mob of the same name overwrites the shared name key but keeps
--its own GUID key, which is exactly the disambiguation we want.
--Is this debuff already recorded FOR THIS MOB?
--
--Checks the GUID store whenever a GUID is known, and only falls back to the name store
--when it is not. The guard used to look at the name alone, and the name store is shared by
--every mob that has ever carried that name: `/octoui-dots` on 2026-08-07 showed one key for
--'Gravelhide Basilisk' against FIVE GUID keys.
--
--So the second basilisk to be hit with a given effect was treated as already known, AddEffect
--never ran, its own GUID store never received the effect, and no timer appeared. The player's
--own casts were unaffected because they commit through AddPending/PersistPending, which has
--no such guard -- which is exactly why DoTs behaved and a PROC like Shadow Vulnerability did
--not. Reported as "shadow vulnerability timer didn't appear instantly".
function lib:HasEffect(unit, unitlevel, effect, guid)
	local store = (guid and lib.objects[guid]) or lib.objects[unit]

	return store and store[unitlevel] and store[unitlevel][effect] and true or false
end

--A GUID ON ITS OWN IS ENOUGH. It did not used to be: no name meant no record at all, and
--UnitName(guid) is SuperWoW resolving a GUID against the client's object list, which answers
--only for a mob currently in range. Dot something, turn away or run on, and your own cast was
--dropped on the floor -- the timer never existed rather than being wrong.
--
--Cursive-Raid never has this problem because it keys everything by target GUID and asks for
--a name only when it draws one. The GUID is the better key anyway: it is exact where a name
--is shared by every mob of that type. So a name is now optional, and its absence costs only
--the name-keyed alias and the frame refresh -- neither of which means anything for a mob no
--unit frame is showing.
function lib:AddEffect(unit, unitlevel, effect, duration, caster, guid)
	if not effect then return end
	if not unit and not guid then return end
	unitlevel = unitlevel or 0

	local store = unit or guid
	if not lib.objects[store] then lib.objects[store] = {} end
	if not lib.objects[store][unitlevel] then lib.objects[store][unitlevel] = {} end
	if not lib.objects[store][unitlevel][effect] then lib.objects[store][unitlevel][effect] = {} end

	local entry = lib.objects[store][unitlevel][effect]
	lastspell = entry

	entry.effect = effect
	entry.start_old = entry.start
	entry.start = GetTime()
	entry.duration = duration or lib:GetDuration(effect, nil, caster == "player")

	--A KNOWN CASTER IS NEVER DOWNGRADED TO NIL. The catch-all aura scan calls this with no
	--caster, and letting that overwrite an effect already recorded as the player's would
	--take the green border off a dot they are still holding. Only a fresh entry -- one the
	--expiry path has already deleted -- starts out ownerless again.
	entry.caster = caster or entry.caster

	--Every route to "the player cast this" passes through here, so this is the one place
	--the own-cast record has to be written. See lib.owncasts.
	if caster == "player" and guid then
		lib:NoteOwnCast(guid, effect, entry.duration)
	end

	--A known cast beats a recent expiry: recasting the dot yourself must start a real timer
	--rather than being mistaken for the icon of the one that just dropped. Only the
	--catch-all scan, which passes no caster, is ever suppressed.
	if caster then
		lib:ClearExpired(unit, guid, effect)
	end

	--Filed under the GUID as well whenever both are known, so the two keys share one table
	--and cannot drift apart.
	if guid and guid ~= store then
		if not lib.objects[guid] then lib.objects[guid] = {} end
		if not lib.objects[guid][unitlevel] then lib.objects[guid][unitlevel] = {} end
		lib.objects[guid][unitlevel][effect] = entry
	end

	if unit then lib:RefreshUnitFrames(unit) end
end

--[[
	Tell any unit frame showing this unit to redraw its auras.

	Reported 2026-08-07: a DoT's timer did not appear on the target frame until something
	else was cast at the mob. The cause is an ordering race that this library creates
	deliberately. A cast is recorded as PENDING and only committed 0.1s later by
	PersistPending -- that delay is load-bearing, and its own comment says why: "without
	this every resisted DoT would start a countdown."

	But UNIT_AURA fires when the debuff actually lands, which is INSIDE that window. The
	aura element draws its icon, asks here for a duration, gets nothing because the commit
	has not happened yet, and draws no timer. Nothing tells it to look again, so the icon
	sits there untimed until the next UNIT_AURA -- i.e. until another debuff lands, which
	is exactly the "cast another one and it appears" symptom.

	So the display is refreshed when the duration commits rather than only when the aura
	changes. The 0.1s delay stays.

	UnitName on a unit TOKEN is the cheap form and is fine per event. The expensive one is
	UnitName(guid), which is SuperWoW resolving a GUID against the object list -- see the
	note in Modules/Misc/ThreatModel.lua about never putting that in a hot path.
]]
function lib:RefreshUnitFrames(unitName)
	if not unitName then return end

	local oUF = _G.ElvUF
	if not (oUF and oUF.objects) then return end

	for i = 1, getn(oUF.objects) do
		local frame = oUF.objects[i]
		--Skipped before UnitName is called, so frames with no aura display cost a table
		--lookup rather than an API call.
		if frame and frame.unit and (frame.Debuffs or frame.Auras) then
			if UnitName(frame.unit) == unitName then
				if frame.Debuffs and frame.Debuffs.ForceUpdate then frame.Debuffs:ForceUpdate() end
				if frame.Auras and frame.Auras.ForceUpdate then frame.Auras:ForceUpdate() end
			end
		end
	end
end

--[[
	Own casts the duration table has never heard of.

	A spell with no entry cannot be timed, and until now that failed in silence: the icon
	appeared with no countdown and nothing anywhere said why. The table is generated from
	spell NAMES, so anything this realm added or renamed simply is not in it -- which is the
	one failure mode a player cannot diagnose from the outside.

	Most of what lands here is expected and harmless: every direct-damage spell you cast has
	no duration either. The point is that a DoT of yours showing up in this list is the
	answer, in one line, to "why is my dot not timed". Newest first, capped, deduplicated,
	and read back by /octoui-dots. Same shape as AutoDismount's record of error strings it
	did not recognise, and for the same reason.
]]
lib.untracked = {}

--[[
	EFFECTS WHOSE TIMER HAS JUST RUN OUT.

	Reported 2026-08-15: a dot of yours drops off and reappears for a moment showing its FULL
	duration. The catch-all scan is what does it. GetTimeLeft deletes an entry the instant it
	expires, and the scan below then finds the icon still on the mob, asks HasEffect, is told
	no, and re-adds it -- with a nil duration, which AddEffect fills in as the whole unhasted
	length. The debuff really drops a moment later and the phantom timer goes with it.

	The scan cannot tell "a debuff I have never seen" from "a debuff I expired a heartbeat
	ago", so it is told. A mark is left when a timer runs out, and while that mark is fresh
	the scan leaves the effect alone: the icon shows with no countdown, which is the honest
	answer, rather than a countdown that is wrong by its whole duration.

	The mark is CLEARED by any known cast -- see AddEffect -- so recasting the dot yourself
	starts a real timer immediately and is never suppressed.
]]
lib.expired = {}

local EXPIRY_GRACE = 8

function lib:MarkExpired(unitname, guid, effect)
	if not effect then return end

	local now = GetTime()
	for _, key in ipairs({unitname, guid}) do
		if key then
			if not lib.expired[key] then lib.expired[key] = {} end
			lib.expired[key][effect] = now
		end
	end
end

function lib:ClearExpired(unitname, guid, effect)
	if not effect then return end

	for _, key in ipairs({unitname, guid}) do
		if key and lib.expired[key] then lib.expired[key][effect] = nil end
	end
end

--Self-cleaning: a stale mark is dropped as it is found, so nothing has to sweep the table.
function lib:RecentlyExpired(unitname, guid, effect)
	if not effect then return false end

	for _, key in ipairs({unitname, guid}) do
		local when = key and lib.expired[key] and lib.expired[key][effect]
		if when then
			if (GetTime() - when) <= EXPIRY_GRACE then return true end
			lib.expired[key][effect] = nil
		end
	end

	return false
end

function lib:NoteUntracked(name)
	if not name then return end

	local list = lib.untracked
	for i = 1, getn(list) do
		if list[i] == name then return end
	end

	tinsert(list, 1, name)
	while getn(list) > 12 do
		tremove(list)
	end
end

--The GUID of the unit a name refers to, when we can be certain which one it is.
--SuperWoW returns it as a second value from UnitExists.
function lib:GuidForName(name)
	if not name then return end
	if UnitName("target") ~= name then return end

	local _, guid = UnitExists("target")
	return guid
end

function lib:UpdateDuration(unit, unitlevel, effect, duration)
	if not unit or not effect or not duration then return end
	unitlevel = unitlevel or 0

	if lib.objects[unit] and lib.objects[unit][unitlevel] and lib.objects[unit][unitlevel][effect] then
		lib.objects[unit][unitlevel][effect].duration = duration
	end
end

function lib:RevertLastAction()
	if not lastspell then return end
	lastspell.start = lastspell.start_old
	lastspell.start_old = nil
end

--[[ pending spells ]]--
--[[
	A cast is recorded but not committed: it only becomes a timer once the combat log
	confirms the debuff landed, or the next frame ticks over with nothing contradicting it.
	Without this every resisted DoT would start a countdown.

	ONE PENDING CAST PER EFFECT, not one in total. It used to be a single six-slot list with
	`if lib.pending[3] then return end` in front of it, so casting a second dot inside the
	0.1s commit window silently threw it away.

	That is what produced the reported symptom: apply four dots back to back, and the ones
	that lost the slot were never recorded as YOURS at cast time. Their entry was created
	instead by the catch-all aura scan, which knows no caster -- so for the moment between
	the debuff landing and UNIT_CASTEVENT arriving, one dot had no green border and anything
	asking "are all four mine" got told no. A macro gated on that then picked the wrong
	spell, which is exactly how it was noticed.
]]
function lib:AddPending(unit, unitlevel, effect, duration, caster)
	if not unit or not effect or not duration or duration <= 0 then return end

	local durations = Durations()
	if not (durations and durations[effect]) then return end

	lib.pending[effect] = {
		unit = unit,
		level = unitlevel or 0,
		duration = duration,
		caster = caster,
		guid = lib:GuidForName(unit)
	}

	E:Delay(0.1, function() lib:PersistPending(effect) end)
end

--Named effect only, or everything when called bare.
function lib:RemovePending(effect)
	if effect then
		lib.pending[effect] = nil
		return
	end

	for name in pairs(lib.pending) do
		lib.pending[name] = nil
	end
end

function lib:PersistPending(effect)
	if effect then
		local entry = lib.pending[effect]
		if not entry then return end

		lib:AddEffect(entry.unit, entry.level, effect, entry.duration, entry.caster, entry.guid)
		lib.pending[effect] = nil
		return
	end

	--Assigning nil to the key pairs() is on is the one mutation the iterator allows.
	for name, entry in pairs(lib.pending) do
		lib:AddEffect(entry.unit, entry.level, name, entry.duration, entry.caster, entry.guid)
		lib.pending[name] = nil
	end
end

--Any effect currently waiting to commit. Only the channel code wants this, and only because
--SPELLCAST_CHANNEL_START calls every spell "Channeling" and has to guess the name.
function lib:AnyPending()
	local name = next(lib.pending)
	return name
end

--[[
	TICK COUNTING -- the only honest timer for our own damage-over-time effects.

	Measured 2026-08-15, two fights, five spells (OctWoW Enhancer\docs\DLL_LANDSCAPE.md):
	OctoWoW does not run periodic effects at their declared interval. Observed spacing
	divided by the DBC amplitude falls into two tight clusters -- about 0.92 all the time,
	and about 0.65 while a haste effect is up -- and the SAME two ratios appear across
	spells whose base intervals are 1s, 2s and 3s.

	The load-bearing fact: the tick COUNT is preserved. Curse of Agony expired naturally
	after exactly twelve ticks, which is what a 24s/2s effect should produce, but delivered
	them in 19.4 seconds. The spacing compresses; the number of ticks does not.

	Two consequences, and they point the same way.

	  * A duration table cannot work. It was 4.6 seconds wrong on that one cast.
	  * NOTHING computed at cast time can work either, table or not, because the rate
	    changes WHILE the effect is running. Curse of Agony ran at 1.83s, sped to 1.26s,
	    and relaxed back to 1.87s inside a single application.

	So stop predicting and start counting. Total ticks is known exactly -- base duration
	over declared interval, both constants -- and every tick that lands is observable. Ticks
	remaining is therefore EXACT even though seconds remaining is an estimate, and it
	re-anchors on every tick. For a rotation that is the better number anyway: refreshing
	is about not clipping a tick.

	This also fixes ownership for free. SPELL_DAMAGE_EVENT_SELF is our own damage, so
	anything counted here is certainly ours -- no caster inference, no contest, no
	"untimed and no border" from an effect the catch-all scan re-learned without a caster.

	Only our own periodic effects. Somebody else's DoT produces no damage events for us,
	and a non-periodic debuff has no ticks to count; both fall through to the table below.
]]
lib.ticks = {}

--Anything not ticked for this long is gone and its entry with it. lib.objects is famously
--never pruned and contributes to the heap climbing about 1 MB a minute; this table is not
--going to repeat that.
local TICK_STALE = 60

--Declared here, above PruneTicks, and not beside the functions that use it further down:
--a local referenced by a function defined EARLIER in the file resolves to a global instead
--and reads nil at runtime. See lib.owndamage for what this is for.
lib.owndamage = {}
local OWN_DAMAGE_WINDOW = 0.20

--[[
	OWNERSHIP IS A SEPARATE FACT FROM DURATION, and treating them as one is why an effect
	the duration table has never heard of draws no owned border.

	Reported 2026-08-15: Dark Harvest gets no green border on nameplates or the target
	frame. It is not in Settings\DebuffDurations -- this realm added it -- so nothing can
	time it, and until now that also meant nothing could say it was yours: the border is
	drawn from GetTimeLeft's caster, and GetTimeLeft has nothing to return for an effect it
	holds no entry for.

	But we now know the caster exactly. AURA_CAST_ON_OTHER carries the casting GUID for
	every aura whether or not any table has heard of the spell, so "this one is mine" is
	answerable even when "how long is left" is not.

	Kept apart from lib.objects deliberately. That store is keyed by name and level and
	carries a duration; this is keyed by GUID and carries a timestamp and nothing else.
	The honest display for an unknown effect is an icon with an owned border and no
	countdown, which is what this produces.
]]
lib.owned = {}

--Long enough for a curse, short enough not to hold a lie forever. The normal lifecycle is
--DEBUFF_REMOVED_OTHER clearing the entry; this is the backstop for when we never see one.
local OWNED_STALE = 300

local tickNames = {}
local function TickSpellName(spellID)
	if not spellID then return nil end

	local cached = tickNames[spellID]
	if cached ~= nil then return cached or nil end

	local name
	if type(SpellInfo) == "function" then
		--SuperWoW. Cached because it resolves against the object list on every call.
		name = SpellInfo(spellID)
	end

	tickNames[spellID] = name or false
	return name
end

--CACHED. UnitExists("player") is SuperWoW resolving against the object list, and this is
--called from the tick path -- once per tick per dot per target. Calling a GUID lookup per
--damage event has been a real defect here once already (HANDOFF: the damage meter). The
--player's own GUID does not change while logged in, so it is resolved once.
local playerGUIDCache = nil
local function TickPlayerGUID()
	if playerGUIDCache then return playerGUIDCache end

	local _, guid = UnitExists("player")
	--Not cached until it answers: this can be called before the object manager has the
	--player, and caching a nil would make it nil for the session.
	if guid then playerGUIDCache = guid end
	return guid
end

--Drops entries nothing has ticked in a while. Called from the tick path, so it costs
--nothing when no dots are running.
function lib:PruneTicks()
	local now = GetTime()

	--Swept here rather than on its own timer: entries are worthless within a fifth of a
	--second and this runs on every tick of every dot.
	for guid, when in pairs(lib.owndamage) do
		if (now - when) > OWN_DAMAGE_WINDOW then lib.owndamage[guid] = nil end
	end

	for guid, spells in pairs(lib.ticks) do
		local live = false
		for id, rec in pairs(spells) do
			if (now - rec.last) > TICK_STALE then
				spells[id] = nil
			else
				live = true
			end
		end
		if not live then lib.ticks[guid] = nil end
	end
end

--Seeded from AURA_CAST_ON_OTHER, whose arg6 carries the declared tick interval in ms --
--the DBC amplitude, handed over at application time. A refresh restarts the count, which
--is why this resets `seen` rather than skipping an effect it already knows.
function lib:NoteTickSpell(guid, spellID, intervalMs)
	if not (guid and spellID and intervalMs and intervalMs > 0) then return end

	local effect = TickSpellName(spellID)
	if not effect then return end

	--The table is unreliable for SECONDS but reliable for tick COUNT, because the count is
	--exactly what the acceleration preserves. Rank is unknown from a spell id, so this
	--takes the max rank -- the same assumption the rest of the library makes.
	local base = lib:GetDuration(effect, nil, false)
	if not base or base <= 0 then
		lib:NoteUntracked(effect)
		return
	end

	local interval = intervalMs / 1000
	local total = floor((base / interval) + 0.5)
	if total < 1 then return end

	if not lib.ticks[guid] then lib.ticks[guid] = {} end

	lib.ticks[guid][spellID] = {
		effect   = effect,
		total    = total,
		seen     = 0,
		declared = interval,
		interval = interval,
		start    = GetTime(),
		last     = GetTime(),
		--Resolved once per application, not per tick. Needed to force the unit frames to
		--re-read when the rate changes; see NoteTick.
		name     = UnitName(guid),
	}
end

--Unit frames take ONE snapshot of duration and expiration when the aura set changes and
--then count down from it linearly. That is correct while the rate holds, and wrong the
--moment it does not: a dot that speeds up mid-application would go on draining at the old
--rate until something else happened to refresh the icon.
--
--Nameplates poll GetTimeLeft on their own update cycle and need no help. The unit frames
--do, so they are told -- but only when the rate has ACTUALLY moved, because forcing an
--update on every tick of every dot would be several full aura rebuilds a second for a
--number that usually has not changed.
local TICK_RATE_TOLERANCE = 0.10
local lastTickRefresh = 0

local function TickRateChanged(rec, oldInterval)
	if not oldInterval or oldInterval <= 0 then return false end

	local drift = (rec.interval - oldInterval) / oldInterval
	if drift < 0 then drift = -drift end
	if drift < TICK_RATE_TOLERANCE then return false end

	--Several dots re-rate together when one haste effect lands. One refresh covers them.
	local now = GetTime()
	if (now - lastTickRefresh) < 0.2 then return false end
	lastTickRefresh = now

	return true
end

--One tick landed. The observed interval is kept as the estimate for the next one, which is
--what makes this track a haste effect coming and going instead of averaging it away.
function lib:NoteTick(guid, spellID)
	if not (guid and spellID) then return end

	local rec = lib.ticks[guid] and lib.ticks[guid][spellID]
	if not rec then return end

	local now = GetTime()
	local oldInterval = rec.interval

	if rec.seen > 0 then
		local gap = now - rec.last
		--A gap far longer than declared means we missed one, or the effect was refreshed
		--and reseeded. Do not let that poison the rate estimate.
		if gap > 0 and gap < (rec.declared * 2) then rec.interval = gap end
	end

	rec.seen = rec.seen + 1
	rec.last = now

	--The unit frames are counting down from a snapshot taken at the old rate.
	if rec.name and TickRateChanged(rec, oldInterval) then
		lib:RefreshUnitFrames(rec.name)
	end

	lib:PruneTicks()
end

function lib:ClearTicks(guid, spellID)
	if not guid or not lib.ticks[guid] then return end

	if spellID then
		lib.ticks[guid][spellID] = nil
	else
		lib.ticks[guid] = nil
	end
end

--[[
	OUR OWN DAMAGE, PER UNIT, for a moment.

	A proc has no caster on the wire, so the only evidence it is ours is that our damage
	landed on that unit in the same instant. Both events carried the same timestamp in the
	measured case; the window is deliberately small, because it is standing in for
	causation and a wide one would start claiming other people's procs.

	One entry per unit, overwritten, and swept on the same schedule as the tick store, so
	this cannot become another table that only ever grows.
]]
function lib:NoteOwnDamage(guid)
	if not guid then return end
	lib.owndamage[guid] = GetTime()
end

function lib:DamagedRecently(guid)
	local when = guid and lib.owndamage[guid]
	if not when then return false end

	if (GetTime() - when) > OWN_DAMAGE_WINDOW then
		lib.owndamage[guid] = nil
		return false
	end

	return true
end

--[[ ownership, independent of whether anything can be timed ]]--

function lib:NoteOwned(guid, effect)
	if not (guid and effect) then return end

	if not lib.owned[guid] then lib.owned[guid] = {} end
	lib.owned[guid][effect] = GetTime()
end

function lib:ClearOwned(guid, effect)
	if not guid or not lib.owned[guid] then return end

	if effect then
		lib.owned[guid][effect] = nil
	else
		lib.owned[guid] = nil
	end
end

--Returns "player" or nil, in the same vocabulary GetTimeLeft uses for its third value.
--Self-cleaning, so a stale entry is dropped as it is found.
function lib:OwnedEffect(guid, effect)
	if not (guid and effect and lib.owned[guid]) then return end

	local when = lib.owned[guid][effect]
	if not when then return end

	if (GetTime() - when) > OWNED_STALE then
		lib.owned[guid][effect] = nil
		return
	end

	--Once anyone else has cast this effect here, ownership is contested and the border
	--stops being ours to draw -- the same veto GetTimeLeft applies to a timed entry.
	if lib:Contested(guid, effect) and not lib:OwnCastLive(guid, effect) then return end

	return "player"
end

--Returns: duration, timeleft, caster -- the same shape GetTimeLeft hands back.
--
--A fully resisted tick fires no damage event, so `seen` can run low and the estimate long.
--It is clamped against the declared schedule so it can never claim more time than the
--effect could possibly have left.
function lib:TickTimeLeft(guid, effect, spellID)
	if not (guid and effect and lib.ticks[guid]) then return end

	--EXACT BY SPELL ID WHEN WE HAVE ONE. The tick table is keyed by the id we
	--actually cast, so an id from the icon matches our record or it does not --
	--no name in the middle. Ranks are separate ids, so this alone tells our
	--Corruption apart from another warlock's whenever the ranks differ.
	--
	--Falling back to the name is still right for a client with no SuperWoW, where
	--UnitDebuff has no id to give: it is what this did for every icon before.
	if spellID then
		local exact = lib.ticks[guid][spellID]
		if not exact then return end

		local left = exact.total - exact.seen
		if left <= 0 then return end

		local remaining = left * exact.interval
		local ceiling = (exact.start + (exact.total * exact.declared)) - GetTime()
		if ceiling > 0 and remaining > ceiling then remaining = ceiling end
		if remaining <= 0 then return end

		return exact.total * exact.interval, remaining, "player"
	end

	for _, rec in pairs(lib.ticks[guid]) do
		if rec.effect == effect then
			local left = rec.total - rec.seen
			if left <= 0 then return end

			local remaining = left * rec.interval
			local ceiling = (rec.start + (rec.total * rec.declared)) - GetTime()
			if ceiling > 0 and remaining > ceiling then remaining = ceiling end
			if remaining <= 0 then return end

			--Duration reported on the same scale as the estimate, so a bar drawn from
			--timeleft/duration fills correctly rather than jumping when the rate changes.
			return rec.total * rec.interval, remaining, "player"
		end
	end
end

--How many ticks are left, which is the exact number and the one worth showing.
--Returns: ticksLeft, totalTicks, secondsToNextTick
function lib:TicksLeft(guid, effect)
	if not (guid and effect and lib.ticks[guid]) then return end

	for _, rec in pairs(lib.ticks[guid]) do
		if rec.effect == effect then
			local nextIn = (rec.last + rec.interval) - GetTime()
			if nextIn < 0 then nextIn = 0 end
			return rec.total - rec.seen, rec.total, nextIn
		end
	end
end

--[[ query ]]--
--Takes a name the caller already has rather than resolving one itself. The nameplate
--element caches names per icon slot and only rescans when the icon changes; making
--this scan instead would put a tooltip scan on every debuff of every plate five
--times a second, which is exactly what that cache exists to avoid.
--Returns: duration, timeleft, caster
--[[
	WHICH BRANCH DECIDED THE CASTER.

	GetTimeLeft can answer "player" from four different places, and when the wrong
	debuff draws an owned border the only useful question is which of them said so.
	Reading the code cannot answer it -- I have now traced it twice and been wrong
	twice -- so this mirrors GetTimeLeft's order exactly and reports the branch
	instead of the verdict.

	It must stay in step with GetTimeLeft below. It is a report, so it deliberately
	does NOT mutate: no expiring entries, no dropping stale records.
]]
function lib:CasterProvenance(unitname, unitlevel, effect, guid)
	if not effect or effect == "" then
		return "rejected", "no effect name (scan failed)"
	end

	local _, tickLeft = lib:TickTimeLeft(guid, effect)
	if tickLeft then
		--The one branch with no contested check and no own-cast check in front of it.
		return "tick", "tick counter says player, unconditionally"
	end

	local owned = lib:OwnedEffect(guid, effect)

	local store = (guid and lib.objects[guid]) or (unitname and lib.objects[unitname])
	local byGuid = guid and lib.objects[guid] and true or false
	if not store then
		return "owned-only", owned and "lib.owned says player" or "nothing known"
	end

	unitlevel = unitlevel or 0
	local entry = (store[unitlevel] and store[unitlevel][effect]) or (store[0] and store[0][effect])
	if not (entry and entry.start and entry.duration) then
		return "owned-only", owned and "lib.owned says player" or "no timed entry"
	end

	if (entry.start + entry.duration) < GetTime() then
		return "expired", owned and "expired, lib.owned still says player" or "expired"
	end

	local why = (byGuid and "store entry by GUID" or "store entry by NAME (shared by every mob so named)")
	if entry.caster == "player" then
		if guid and lib:Contested(guid, effect) and not lib:OwnCastLive(guid, effect) then
			return "contested", why.." says player, vetoed as contested"
		end
		return "store", why.." says player"
	end

	return "store", why..(entry.caster and (" says "..tostring(entry.caster)) or " has no caster")
end

function lib:GetTimeLeft(unitname, unitlevel, effect, guid, spellID)
	if not effect then return end

	--Counted ticks beat a table lookup whenever we have them. Only our own periodic
	--effects get counted, so everything else falls straight through to the logic below and
	--behaves exactly as it did before.
	local tickDuration, tickLeft, tickCaster = lib:TickTimeLeft(guid, effect, spellID)
	if tickLeft then return tickDuration, tickLeft, tickCaster end

	--Known to be ours even when nothing can time it -- an effect this realm added that the
	--duration table has never heard of. Returned on every path below that has no timer to
	--offer, so the caller draws an owned border with no countdown instead of neither.
	local owned = lib:OwnedEffect(guid, effect)

	--SuperWoW has a "GUID in combat log/events" option. With it on, the log hands us
	--GUIDs where it would otherwise hand us names, so the store ends up keyed by GUID
	--and a lookup by name finds nothing. Try both rather than depending on a setting
	--we do not control -- and when it *is* on, two mobs of the same name finally get
	--their own timers instead of sharing one.
	local store = (guid and lib.objects[guid]) or (unitname and lib.objects[unitname])
	if not store then return nil, nil, owned end

	unitlevel = unitlevel or 0
	local entry = (store[unitlevel] and store[unitlevel][effect]) or (store[0] and store[0][effect])
	if not (entry and entry.start and entry.duration) then return nil, nil, owned end

	if (entry.start + entry.duration) < GetTime() then
		--expired: drop it rather than hand back a negative timer
		if store[unitlevel] then store[unitlevel][effect] = nil end
		if store[0] then store[0][effect] = nil end

		--Remembered, so the catch-all scan does not see the icon still on the mob a
		--fraction of a second later and put the effect back at its full duration. See
		--lib.expired.
		lib:MarkExpired(unitname, guid, effect)

		--The timer is gone; whose it was is not. An effect that outlives its table
		--duration -- which the acceleration measurements show is routine -- should keep
		--its owned border rather than turning grey the moment the countdown lapses.
		return nil, nil, owned
	end

	--The timer is still ours to report -- it is the same spell with the same duration either
	--way -- but the OWNERSHIP is not, once anyone else has cast this effect here. Reported
	--as nil rather than "player" so a caller drawing a "this one is mine" border stops
	--drawing it rather than drawing it on both.
	--A cast of the player's own that could still be running outranks the veto: they dotted
	--this mob, so one of these icons is certainly theirs, and taking the timer away from
	--them because a second warlock turned up helps nobody.
	local caster = entry.caster
	if caster == "player" and guid and lib:Contested(guid, effect) and not lib:OwnCastLive(guid, effect) then
		caster = nil
	end

	--CORROBORATION. entry.caster is a claim written at some point in the past by
	--one of several handlers, and every ownership bug this library has had was a
	--handler writing "player" when it should not have. So where better evidence
	--exists, the claim has to agree with it.
	--
	--With a spell id from SuperWoW we can ask two questions the server has
	--already answered:
	--
	--  lib.ticks[guid][spellID]  -- created when WE cast it and fed only by
	--                               SPELL_DAMAGE_EVENT_SELF, which the server
	--                               sends for our own damage and nobody else's
	--  lib.ownspell[guid][effect] -- the id of the spell we cast on this mob
	--
	--Neither answering means we have no record of casting this spell on this mob,
	--so it is not ours however confidently the store says otherwise. That is the
	--case that actually costs damage: a dot you do NOT have showing as yours, so
	--you skip the recast and Dark Harvest accelerates one fewer dot. Two of your
	--own icons being confused with each other is cosmetic by comparison, because
	--the timer on either is still your own tick count.
	--
	--Only applied when a spell id is available. Without SuperWoW there is nothing
	--to corroborate against and this would refuse everything.
	if caster == "player" and spellID and guid then
		local ticked = lib.ticks[guid] and lib.ticks[guid][spellID]
		local cast = lib.ownspell[guid] and lib.ownspell[guid][effect]
		if not (ticked or (cast and cast == spellID)) then
			caster = nil
			if lib.NoteRefusal then lib:NoteRefusal(guid, effect, spellID) end
		end
	end

	return entry.duration, entry.start + entry.duration - GetTime(), caster
end

--Same shape as the modern UnitAura, for callers that do not keep their own cache:
--name, rank, texture, stacks, dtype, duration, timeleft, caster
function lib:UnitDebuff(unit, id)
	--The fourth return is SuperWoW's spell id, and nil without it. Used only to tell two
	--icons of the same effect apart; everything below works the same either way.
	local texture, stacks, dtype, spellID = UnitDebuff(unit, id)
	if not texture then return end

	local effect = mod:ScanAuraName(unit, id, true) or ""

	--WITH THE GUID. This asked by name and level only, and the name store is shared by every
	--mob that has ever carried that name -- it accumulates, and GetTimeLeft prefers the GUID
	--precisely to avoid it. So a caster read through here came from whichever mob of that
	--name last wrote the effect, not from this one. Same class as the bug HANDOFF 12c fixed
	--in HasEffect, missed at this call site.
	--
	--SuperWoW returns the GUID as UnitExists' second value; without it this degrades to the
	--old name lookup rather than failing.
	local _, guid = UnitExists(unit)
	local duration, timeleft, caster = lib:GetTimeLeft(UnitName(unit), UnitLevel(unit),
		effect, guid, spellID)

	--One green border per debuff, not one per icon carrying that name. Tagged "uf" because
	--unit frames sort and filter their icons, so their index numbering is not the nameplate's.
	if caster == "player" and not lib:ClaimOwn("uf", guid, effect, id, spellID) then
		caster = nil
	end

	return effect, nil, texture, stacks, dtype, duration, timeleft, caster
end

--[[ data gathering ]]--
lib.removePending = {
	SPELLIMMUNESELFOTHER, IMMUNEDAMAGECLASSSELFOTHER, SPELLMISSSELFOTHER,
	SPELLRESISTSELFOTHER, SPELLEVADEDSELFOTHER, SPELLDODGEDSELFOTHER,
	SPELLDEFLECTEDSELFOTHER, SPELLREFLECTSELFOTHER, SPELLPARRIEDSELFOTHER,
	SPELLLOGABSORBSELFOTHER, SPELLFAILCASTSELF
}

lib:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
lib:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
lib:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
lib:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
lib:RegisterEvent("PLAYER_TARGET_CHANGED")
lib:RegisterEvent("SPELLCAST_STOP")
--CHANNELS. A channelled effect is not a fixed-length debuff: it lasts exactly as long as the
--channel and every tick refreshes it. Timing one off the duration table starts the countdown
--at the FIRST TICK -- which is where the periodic-damage branch picks it up, with no caster
--and so no haste -- and the timer then runs out while the channel is still going. Measured
--2026-08-08: Drain Life recorded 5.0s and the debuff was still on the mob 5.4s later, so the
--icon sat there untimed.
--
--This event carries the channel's real length in milliseconds, which is the only exact
--figure available and already accounts for haste, talents and rank without a table lookup.
--SuperWoW names the spell outright, which is the only reliable way to know WHAT is being
--channelled. SPELLCAST_CHANNEL_START carries the exact length but calls every spell
--"Channeling" (measured 2026-08-08), and inferring the name from the last cast fails the
--moment nampower queues one -- which is most of the time in a real rotation.
--    arg1 caster GUID, arg2 target GUID, arg3 START/CAST/CHANNEL/FAIL, arg4 spell ID
lib:RegisterEvent("UNIT_CASTEVENT")

--[[
	NAMPOWER'S AURA EVENTS. These apply to EVERY debuff, from every caster, not just our
	own damage-over-time effects -- which is the point of using them.

	AURA_CAST_ON_OTHER fires at the moment an aura is actually applied, and carries:
	    arg1 spell id, arg2 caster GUID, arg3 target GUID, arg5 aura type,
	    arg6 declared tick interval in ms (0 for anything non-periodic)

	Two things that were previously guessed become exact for all of them:

	  START TIME. A debuff learned from the periodic-damage branch starts its countdown at
	  the FIRST TICK, not at application -- already noted below for channels, and just as
	  wrong for everything else. This event is the application.

	  OWNERSHIP. arg2 against the player's GUID is a fact. The library currently infers it,
	  and the catch-all scan re-learns effects with no caster at all, which is where an
	  icon with no owned border comes from.

	Gated on the effect being in the duration table, so an unknown spell -- or a BUFF, which
	this event also fires for -- does not get filed into the debuff store. Unknown ones are
	recorded by NoteUntracked exactly as before, so "why is my dot not timed" still answers
	itself.

	Measured 2026-08-15: arg3 can be nil for a unit outside the object manager. Guarded.
]]
lib:RegisterEvent("AURA_CAST_ON_OTHER")
lib:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
lib:RegisterEvent("DEBUFF_REMOVED_OTHER")

--[[
	PROCS DO NOT FIRE AURA_CAST_ON_OTHER. Measured 2026-08-16.

	Shadow Vulnerability lands from an Improved Shadow Bolt crit, and it arrives with a
	DEBUFF_ADDED_OTHER and nothing else -- no aura-cast event at all, because nobody cast
	it. That event carries the caster's LEVEL (arg5) but not their GUID, so on its own it
	cannot say whose the debuff is. Which is why this spell has always drawn untimed and
	unowned, and why it is the one HANDOFF item 12c is about.

	The capture shows the answer sitting right next to it:

	    14.46  SPELL_DAMAGE_EVENT_SELF  mob | me | 11661 | 1136 | 0,0,0 | 2
	    14.46  DEBUFF_ADDED_OTHER       mob | 1 | 17794 | 1 | 60 | 32

	Our own Shadow Bolt hit that unit in the same instant -- and the trailing 2 is the crit
	flag; every non-crit in the same fight had 0 there. A debuff appearing on a unit we just
	damaged is a proc off our own damage, so it is ours.

	Deliberately narrow. DEBUFF_ADDED_OTHER is world-scoped like every other nampower aura
	event -- the same capture has one for a debuff on the pet -- so an entry is written only
	when our own damage on that exact GUID is fresh enough to have caused it.
]]
lib:RegisterEvent("DEBUFF_ADDED_OTHER")

lib:RegisterEvent("SPELLCAST_CHANNEL_START")
lib:RegisterEvent("SPELLCAST_CHANNEL_UPDATE")
lib:RegisterEvent("SPELLCAST_CHANNEL_STOP")
lib:RegisterEvent("UNIT_AURA")

if playerClass == "PALADIN" then
	lib:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
end

lib:SetScript("OnEvent", function()
	--paladin seals refresh their judgement on every melee hit
	if event == "CHAT_MSG_COMBAT_SELF_HITS" then
		local judgements = Judgements()
		if not judgements then return end

		if cmatch(arg1, COMBATHITSELFOTHER) or cmatch(arg1, COMBATHITCRITSELFOTHER) then
			local name, level = UnitName("target"), UnitLevel("target")
			if name and lib.objects[name] then
				for seal in pairs(judgements) do
					if level and lib.objects[name][level] and lib.objects[name][level][seal] then
						lib:AddEffect(name, level, seal, nil, "player", lib:GuidForName(name))
					elseif lib.objects[name][0] and lib.objects[name][0][seal] then
						lib:AddEffect(name, 0, seal, nil, "player", lib:GuidForName(name))
					end
				end
			end
		end

	elseif event == "AURA_CAST_ON_OTHER" then
		--arg1 spell id, arg2 caster GUID, arg3 target GUID, arg5 aura type, arg6 interval ms
		local spellID, casterGUID, targetGUID, intervalMs = arg1, arg2, arg3, arg6
		local effect = targetGUID and TickSpellName(spellID)

		if effect then
			local durations = Durations()
			local playerGUID = TickPlayerGUID()
			local mine = playerGUID and casterGUID == playerGUID

			--OWNERSHIP FIRST, and unconditionally. This is the one thing we now know for
			--certain about any aura from any caster, and it must not depend on the
			--duration table having heard of the spell -- Dark Harvest is not in it, which
			--is exactly why it drew no owned border.
			if mine then lib:NoteOwned(targetGUID, effect) end

			--OUR OWN CASTS ONLY, and this restriction is load-bearing.
			--
			--Written first as "any caster", which was wrong and caused a regression the
			--same day: AURA_CAST_ON_OTHER fires for EVERY unit in range, and AddEffect
			--writes lib.objects[unitName] -- the store every mob of that name shares. So
			--another warlock's Improved Shadow Bolt, landing on any mob of the same name
			--anywhere in range, wrote an entry that the current target then displayed.
			--Reported as Shadow Vulnerability appearing on the target with no Shadow Bolt
			--ever cast.
			--
			--Somebody else's debuff keeps the routes it already had -- the combat log and
			--the UNIT_AURA sweep, both of which are scoped to the target. The only thing
			--this event is used for now is what it alone can answer: that a debuff is OURS
			--and exactly when it landed.
			if mine and durations and durations[effect] then
				--AddEffect fills the duration from the table; for our own periodic effects
				--the tick counter overrides that in GetTimeLeft, which is where it belongs.
				local name = UnitName(targetGUID) or targetGUID
				local level = (UnitName("target") == name and UnitLevel("target")) or 0
				lib:AddEffect(name, level, effect, nil, "player", targetGUID)
			elseif mine then
				--Still untimed, and still reported so /octoui-dots can name it -- but it
				--will now at least draw as ours.
				lib:NoteUntracked(effect)
			end

			--Periodic, and ours to count. arg6 is 0 for everything non-periodic.
			if mine and intervalMs and intervalMs > 0 then
				lib:NoteTickSpell(targetGUID, spellID, intervalMs)
			end
		end

	elseif event == "SPELL_DAMAGE_EVENT_SELF" then
		--arg1 target GUID, arg2 caster GUID, arg3 spell id, arg4 amount,
		--arg5 "block,absorb,resist", arg7 hit type (2 = crit).
		local playerGUID = TickPlayerGUID()
		if playerGUID and arg2 == playerGUID then
			lib:NoteTick(arg1, arg3)
			--Remembered so a debuff appearing on this unit a fraction of a second later
			--can be recognised as a proc off this hit. See DEBUFF_ADDED_OTHER.
			lib:NoteOwnDamage(arg1)
		end

	elseif event == "DEBUFF_ADDED_OTHER" then
		--arg1 target GUID, arg3 spell id.
		--
		--THIS EVENT CANNOT ANSWER OWNERSHIP AND NO LONGER PRETENDS TO. It carries
		--no caster GUID, and what stood here inferred one from DamagedRecently --
		--"did I damage this mob in the last 0.2 seconds". Reported 2026-08-21 as
		--other warlocks' dots reading as the player's, and the capture showed far
		--worse than that: a warlock's store held Demoralizing Roar, Growl, Rupture,
		--Arcane Missiles, Demoralizing Shout and Sunder Armor all as `caster
		--player`. None of them are warlock spells.
		--
		--Three things compound. NoteOwnDamage fires on every DoT tick, so with
		--three DoTs up the window is open a large share of the time. Any debuff
		--anyone applies inside it gets claimed. And AddEffect never downgrades a
		--known caster, so each mistake is permanent -- the error only accumulates,
		--which is why a long fight ends with most of the mob's debuffs "yours".
		--
		--Ownership now comes only from AURA_CAST_ON_OTHER, which carries a real
		--caster GUID and is checked against the player's. The timing this branch
		--recorded is still worth having, so the AddEffect stays with a NIL caster:
		--it still stamps the exact application time -- which is what stops the
		--shared name store handing a new mob the previous one's leftover countdown
		--- and, because a nil never overwrites a known caster, it cannot take a
		--genuine claim away either.
		--
		--The cost is procs of the player's own damage that have no cast event at
		--all, Improved Shadow Bolt's Shadow Vulnerability being the obvious one.
		--Those lose their owned border. That is one specific effect drawn grey
		--against every debuff in the raid drawn green, which is not a close call.
		local effect = arg1 and TickSpellName(arg3)
		if effect and lib:DamagedRecently(arg1) then
			local durations = Durations()
			if durations and durations[effect] then
				local name = UnitName(arg1) or arg1
				local level = (UnitName("target") == name and UnitLevel("target")) or 0
				lib:AddEffect(name, level, effect, nil, nil, arg1)
			else
				lib:NoteUntracked(effect)
			end
		end

	elseif event == "DEBUFF_REMOVED_OTHER" then
		--arg1 target GUID, arg3 spell id. arg2 is a COMPACTED DISPLAY slot that collides
		--on mass removal -- five removals all reported slot 1 at one mob death on
		--2026-08-15 -- so it is deliberately not used here. The spell id is unambiguous.
		lib:ClearTicks(arg1, arg3)
		lib:ClearOwned(arg1, TickSpellName(arg3))

	elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
		local unit, effect = cmatch(arg1, AURAADDEDOTHERHARMFUL)
		if unit and effect then
			local unitlevel = (UnitName("target") == unit and UnitLevel("target")) or 0
			local guid = lib:GuidForName(unit)
			if not lib:HasEffect(unit, unitlevel, effect, guid)
				and not lib:RecentlyExpired(unit, guid, effect) then
				lib:AddEffect(unit, unitlevel, effect, nil, nil, guid)
			end
		end

	elseif (event == "UNIT_AURA" and arg1 == "target") or event == "PLAYER_TARGET_CHANGED" then
		--catch debuffs that were applied without us seeing the message
		for i = 1, 16 do
			local texture = UnitDebuff("target", i)
			if not texture then return end

			local effect = mod:ScanAuraName("target", i, true)
			if effect and effect ~= "" then
				local unit, unitlevel = UnitName("target"), UnitLevel("target") or 0
				local guid = lib:GuidForName(unit)
				--This is the scan that caused the phantom full-duration timer: it sees an
				--icon with no stored countdown and assumes the debuff is new. See lib.expired.
				if unit and not lib:HasEffect(unit, unitlevel, effect, guid)
					and not lib:RecentlyExpired(unit, guid, effect) then
					lib:AddEffect(unit, unitlevel, effect, nil, nil, guid)
				end
			end
		end

	elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
		for _, msg in pairs(lib.removePending) do
			local effect = cmatch(arg1, msg)
			--Drops only the resisted effect now, where a single shared slot meant any resist
			--cancelled whichever cast happened to be waiting.
			if effect and lib.pending[effect] then
				lib:RemovePending(effect)
				return
			elseif effect and lastspell and lastspell.start_old and lastspell.effect == effect then
				--late arrivals, hunter arrows in particular, land after the cast ended
				lib:RevertLastAction()
				return
			end
		end

	elseif event == "SPELLCAST_CHANNEL_START" then
		--arg1 is the channel length in milliseconds. arg2 is NOT the spell -- measured on
		--this client 2026-08-08, it is the literal string "Channeling" every time:
		--
		--    SPELLCAST_CHANNEL_START  arg1=4700 (number), arg2=Channeling (string)
		--
		--4700 is already haste-adjusted, so it beats anything the duration table can offer.
		--But the name has to come from somewhere else, in falling order of certainty:
		--
		--  the pending cast, when the cast hook saw it;
		--  the last effect written, when it was ours and is a known channel;
		--  the last spell channelled, which is what carries a RE-CHANNEL.
		--
		--That last one is the whole point. nampower queues casts, so a re-channel often does
		--not reach the cast hooks at all -- CHANNEL_START fires regardless, and remembering
		--the name is what lets it refresh the timer anyway. Without it the first channel was
		--timed and every one after it sat untimed, which is the reported bug.
		local ms = tonumber(arg1)
		local durations = Durations()

		--channelEffect is set by UNIT_CASTEVENT below and is the authoritative answer. The
		--other two are fallbacks for a client without SuperWoW.
		local effect = channelEffect
		if not (effect and durations and durations[effect]) then
			effect = lib:AnyPending()
		end
		if not (effect and durations and durations[effect]) then
			--ONLY IF THE LAST WRITE WAS OURS. lastspell is set by every AddEffect,
			--including the ones that record somebody else's debuff with no caster,
			--so this fallback used to adopt whatever happened to be written most
			--recently. Measured 2026-08-22 from the ownership log: a mob's Mind Flay
			--and a Bloodaxe Worg's Demoralizing Shout were both claimed as the
			--player's, purely because they were the last thing stored when a channel
			--started.
			--
			--Checking the caster keeps the case this fallback exists for -- a
			--re-channel of your own spell, where nampower queued the cast and the
			--hooks never saw it -- because that write was yours.
			effect = (lastspell and lastspell.caster == "player") and lastspell.effect or nil
		end

		if ms and ms > 0 and effect and durations and durations[effect] then
			channelEffect = effect
			local unit = UnitName("target")
			if unit then
				lib:AddEffect(unit, UnitLevel("target") or 0, effect, ms / 1000, "player",
					lib:GuidForName(unit))

				--AddEffect sets `lastspell` to the entry it just wrote, so this is the channel's
				--own entry and nothing else. Held by reference rather than by name so that
				--CHANNEL_STOP cannot zero some other effect that happened to be written in
				--between -- a DoT tick lands often enough for that to be a real risk.
				channelEntry = lastspell
			end
		end

	elseif event == "UNIT_CASTEVENT" then
		--Only the player's own channels. A GUID compare rather than a name compare because
		--this fires for every unit in range and names are not unique.
		if SpellInfo then
			local _, playerGUID = UnitExists("player")

			--SOMEONE ELSE casting a tracked effect at a mob. arg1 is the caster's GUID and
			--arg2 the target's, so this is the one moment the client tells us an effect on
			--that mob is not exclusively ours. See lib.contested at the top of the file.
			if playerGUID and arg1 ~= playerGUID and arg3 == "CAST" and arg2 then
				local name = SpellInfo(arg4)
				local durations = Durations()

				if name and durations and durations[name] then
					if not lib.contested[arg2] then lib.contested[arg2] = {} end

					--Held as the time their cast can no longer be up by, not as a flag. Their
					--rank and haste are unknowable, so the unhasted top rank is the longest it
					--could possibly last -- generous on purpose, since the cost of guessing
					--long is a border that stays neutral slightly too long, and the cost of
					--guessing short is claiming their DoT as yours.
					lib.contested[arg2][name] = GetTime() + lib:GetDuration(name, nil, false)
				end
			end

			if playerGUID and arg1 == playerGUID then
				--Rank is the second return and decides the duration; see the note in the CAST
				--branch below for what ignoring it cost.
				local name, rank = SpellInfo(arg4)

				if arg3 == "CHANNEL" then
					if name then channelEffect = name end

				elseif arg3 == "CAST" then
					--A COMPLETED CAST, which is the only reliable notice of a RECAST.
					--
					--The cast hooks miss these whenever nampower queues one, and the
					--periodic-damage path cannot stand in: HasEffect blocks it while the
					--effect is still tracked, so a refreshed DoT keeps the ORIGINAL timer,
					--runs out early, blanks, and only reappears once the store has expired it
					--and a tick re-adds it unhasted. Reported as "blank timer till a new dot
					--is added, then the timer appears"; measured 2026-08-08 on Corruption and
					--Curse of Agony.
					--
					--AddEffect rather than AddPending: this event fires on completion, so
					--there is nothing left to resist. arg2 is the target's GUID, which is also
					--the store's preferred key.
					--
					--THE NAME IS NO LONGER REQUIRED. UnitName(arg2) answers only for a mob the
					--client currently has in its object list, so this used to discard your own
					--cast the moment you dotted something and turned away. AddEffect takes the
					--GUID alone now, and the name is passed when there happens to be one.
					--
					--RANK MATTERS AND WAS BEING THROWN AWAY. SpellInfo returns it as the second
					--value; passing nil meant every own cast was timed at max rank, so a
					--lower-rank DoT ran a timer longer than the debuff.
					local durations = Durations()

					if name and arg2 then
						if durations and durations[name] then
							lib:AddEffect(UnitName(arg2), UnitLevel(arg2) or 0, name,
								lib:GetDuration(name, rank, true), "player", arg2)

							--The id, not just the name. Ranks are separate ids, so this is what
							--tells our icon apart from another caster's when they are running a
							--different rank of the same spell. See lib:ClaimOwn.
							lib:NoteOwnSpell(arg2, name, arg4)
						else
							lib:NoteUntracked(name)
						end
					end
				end
			end
		end

	elseif event == "SPELLCAST_CHANNEL_UPDATE" then
		--Fires when the channel is extended or clipped; arg1 is the NEW remaining time in
		--milliseconds. Measured: arg1=3250 with no name, so it can only apply to the entry
		--CHANNEL_START recorded.
		local ms = tonumber(arg1)
		if channelEntry and ms and ms > 0 then
			channelEntry.start = GetTime()
			channelEntry.duration = ms / 1000
		end

	elseif event == "SPELLCAST_CHANNEL_STOP" then
		--Ends the debuff whether the channel finished or was cut short by moving or the mob
		--dying, so the timer must not outlive it.
		if channelEntry then
			channelEntry.duration = 0
			channelEntry = nil
		end

	elseif event == "SPELLCAST_STOP" then
		lib:PersistPending()
	end
end)

--[[ cast hooks ]]--
--The combat log names the effect but never its rank, and rank decides the duration,
--so the rank has to be read off the spellbook at the moment of casting.
local function SpellInfoByID(id, bookType)
	local name, rank = GetSpellName(id, bookType or BOOKTYPE_SPELL)
	return name, rank
end

local function SpellInfoByName(name)
	if not name then return end

	--strip any rank the caller already supplied: CastSpellByName("Corruption(Rank 3)")
	local plain, rank = name, nil
	local _, _, base, inner = find(name, "^(.-)%((.+)%)$")
	if base and inner then plain, rank = base, inner end
	plain = gsub(plain, "%s+$", "")

	if rank then return plain, rank end

	--no rank given means the highest known one
	local best, bestNum
	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, num = GetSpellTabInfo(tab)
		for id = offset + 1, offset + num do
			local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
			if spellName == plain and spellRank then
				local _, _, n = find(spellRank, "(%d+)%s*$")
				n = tonumber(n) or 0
				if not bestNum or n > bestNum then best, bestNum = spellRank, n end
			end
		end
	end

	return plain, best
end

local function QueueCast(effect, rank)
	if not effect then return end
	--our own cast, so haste applies
	local duration = lib:GetDuration(effect, rank, true)
	lib:AddPending(UnitName("target"), UnitLevel("target"), effect, duration, "player")
end

--This client's hooksecurefunc polyfill takes no "run before" flag and always runs
--after the original, which is what we want: the cast has gone out by then.
hooksecurefunc("CastSpell", function(id, bookType)
	QueueCast(SpellInfoByID(id, bookType))
end)

hooksecurefunc("CastSpellByName", function(name)
	QueueCast(SpellInfoByName(name))
end)

hooksecurefunc("UseAction", function(slot)
	if GetActionText(slot) or not IsCurrentAction(slot) then return end
	QueueCast(mod:ScanActionName(slot))
end)
