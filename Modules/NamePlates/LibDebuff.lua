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
local format, gsub, gfind, find = string.format, string.gsub, string.gfind, string.find
local GetTime = GetTime
local GetComboPoints, GetTalentInfo = GetComboPoints, GetTalentInfo
local UnitName, UnitLevel, UnitClass = UnitName, UnitLevel, UnitClass
local GetSpellName, GetNumSpellTabs, GetSpellTabInfo = GetSpellName, GetNumSpellTabs, GetSpellTabInfo

local lib = CreateFrame("Frame", "OctoUI_LibDebuff")
mod.LibDebuff = lib

lib.objects = {}
lib.pending = {}

local lastspell
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

local captureCache = {}
local function GetCaptures(pattern)
	if not captureCache[pattern] then
		for a, b, c, d, e in gfind(gsub(pattern, "%((.+)%)", "%1"), gsub(pattern, "%d%$", "%%(.-)$")) do
			captureCache[pattern] = {a, b, c, d, e}
		end
	end

	if not captureCache[pattern] then return end
	local r = captureCache[pattern]
	return r[1], r[2], r[3], r[4], r[5]
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
function lib:AddEffect(unit, unitlevel, effect, duration, caster, guid)
	if not unit or not effect then return end
	unitlevel = unitlevel or 0

	if not lib.objects[unit] then lib.objects[unit] = {} end
	if not lib.objects[unit][unitlevel] then lib.objects[unit][unitlevel] = {} end
	if not lib.objects[unit][unitlevel][effect] then lib.objects[unit][unitlevel][effect] = {} end

	local entry = lib.objects[unit][unitlevel][effect]
	lastspell = entry

	entry.effect = effect
	entry.start_old = entry.start
	entry.start = GetTime()
	entry.duration = duration or lib:GetDuration(effect, nil, caster == "player")
	entry.caster = caster

	if guid then
		if not lib.objects[guid] then lib.objects[guid] = {} end
		if not lib.objects[guid][unitlevel] then lib.objects[guid][unitlevel] = {} end
		lib.objects[guid][unitlevel][effect] = entry
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
--A cast is recorded but not committed: it only becomes a timer once the combat log
--confirms the debuff landed, or the next frame ticks over with nothing contradicting
--it. Without this every resisted DoT would start a countdown.
function lib:AddPending(unit, unitlevel, effect, duration, caster)
	if not unit or not duration or duration <= 0 then return end

	local durations = Durations()
	if not (durations and durations[effect]) then return end
	if lib.pending[3] then return end

	lib.pending[1] = unit
	lib.pending[2] = unitlevel or 0
	lib.pending[3] = effect
	lib.pending[4] = duration
	lib.pending[5] = caster
	lib.pending[6] = lib:GuidForName(unit)

	E:Delay(0.1, lib.PersistPending)
end

function lib:RemovePending()
	lib.pending[1] = nil
	lib.pending[2] = nil
	lib.pending[3] = nil
	lib.pending[4] = nil
	lib.pending[5] = nil
	lib.pending[6] = nil
end

function lib:PersistPending(effect)
	if not lib.pending[3] then return end

	if lib.pending[3] == effect or (effect == nil and lib.pending[3]) then
		lib:AddEffect(lib.pending[1], lib.pending[2], lib.pending[3], lib.pending[4], lib.pending[5], lib.pending[6])
	end

	lib:RemovePending()
end

--[[ query ]]--
--Takes a name the caller already has rather than resolving one itself. The nameplate
--element caches names per icon slot and only rescans when the icon changes; making
--this scan instead would put a tooltip scan on every debuff of every plate five
--times a second, which is exactly what that cache exists to avoid.
--Returns: duration, timeleft, caster
function lib:GetTimeLeft(unitname, unitlevel, effect, guid)
	if not effect then return end

	--SuperWoW has a "GUID in combat log/events" option. With it on, the log hands us
	--GUIDs where it would otherwise hand us names, so the store ends up keyed by GUID
	--and a lookup by name finds nothing. Try both rather than depending on a setting
	--we do not control -- and when it *is* on, two mobs of the same name finally get
	--their own timers instead of sharing one.
	local store = (guid and lib.objects[guid]) or (unitname and lib.objects[unitname])
	if not store then return end

	unitlevel = unitlevel or 0
	local entry = (store[unitlevel] and store[unitlevel][effect]) or (store[0] and store[0][effect])
	if not (entry and entry.start and entry.duration) then return end

	if (entry.start + entry.duration) < GetTime() then
		--expired: drop it rather than hand back a negative timer
		if store[unitlevel] then store[unitlevel][effect] = nil end
		if store[0] then store[0][effect] = nil end
		return
	end

	return entry.duration, entry.start + entry.duration - GetTime(), entry.caster
end

--Same shape as the modern UnitAura, for callers that do not keep their own cache:
--name, rank, texture, stacks, dtype, duration, timeleft, caster
function lib:UnitDebuff(unit, id)
	local texture, stacks, dtype = UnitDebuff(unit, id)
	if not texture then return end

	local effect = mod:ScanAuraName(unit, id, true) or ""
	local duration, timeleft, caster = lib:GetTimeLeft(UnitName(unit), UnitLevel(unit), effect)

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

	elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
		local unit, effect = cmatch(arg1, AURAADDEDOTHERHARMFUL)
		if unit and effect then
			local unitlevel = (UnitName("target") == unit and UnitLevel("target")) or 0
			if not (lib.objects[unit] and lib.objects[unit][unitlevel] and lib.objects[unit][unitlevel][effect]) then
				lib:AddEffect(unit, unitlevel, effect, nil, nil, lib:GuidForName(unit))
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
				if unit and not (lib.objects[unit] and lib.objects[unit][unitlevel] and lib.objects[unit][unitlevel][effect]) then
					lib:AddEffect(unit, unitlevel, effect, nil, nil, lib:GuidForName(unit))
				end
			end
		end

	elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
		for _, msg in pairs(lib.removePending) do
			local effect = cmatch(arg1, msg)
			if effect and lib.pending[3] == effect then
				lib:RemovePending()
				return
			elseif effect and lastspell and lastspell.start_old and lastspell.effect == effect then
				--late arrivals, hunter arrows in particular, land after the cast ended
				lib:RevertLastAction()
				return
			end
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
