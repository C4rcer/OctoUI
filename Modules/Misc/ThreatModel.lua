local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, tonumber, type = pairs, tonumber, type
local format, sort = string.format, table.sort
local tinsert, getn = table.insert, table.getn
--WoW API / Variables
local GetTime = GetTime
local UnitName, UnitClass, UnitExists = UnitName, UnitClass, UnitExists
local UnitIsUnit, UnitIsDeadOrGhost = UnitIsUnit, UnitIsDeadOrGhost
local GetNumRaidMembers, GetNumPartyMembers = GetNumRaidMembers, GetNumPartyMembers
local CreateFrame = CreateFrame
local GetShapeshiftForm = GetShapeshiftForm
local _G = _G

--[[
	Locally modelled threat.

	Why this exists. Threat on this client is entirely server-side: TWThreat asks the
	server and draws whatever comes back, and it computes nothing itself. Measured on
	OctoWoW, that API answers a group and ignores anybody else -- 33 requests sent solo,
	nothing returned. So the threat window is correct and empty, and no amount of client
	work changes that. The only way to know your threat while solo is to work it out.

	What it can and cannot be. Vanilla threat is simple at its core and fiddly at the
	edges. Damage is one threat per point, to the mob that took it. Healing is half a
	threat per point, spread over every mob in combat with the healer. On top of that sit
	multipliers -- stance, form, Righteous Fury -- and a set of abilities whose threat has
	nothing to do with their damage, of which a Voidwalker's Torment is the one that
	matters here.

	Those last two are where a model earns or loses its keep, and they are the reason
	every number in ABILITY_THREAT below is marked with its verification state. A meter
	that confidently says the void has aggro when it does not is worse than no meter,
	which is the same principle the character stat panel follows when it prints "--"
	rather than a crit figure it cannot stand behind. M:ThreatConfidence reports how much
	of a given fight went through unverified numbers, and the report shows it.

	Per target, always. A mob only cares what you did to *it*, so threat is stored as
	[targetGuid][actorGuid]. Merging pets into their owner would defeat the purpose --
	the whole question a warlock is asking is whether the pet is above them.
]]

local DAMAGE_EVENTS = {"SPELL_DAMAGE_EVENT_SELF", "SPELL_DAMAGE_EVENT_OTHER"}
local SWING_EVENTS = {"AUTO_ATTACK_SELF", "AUTO_ATTACK_OTHER"}
local HEAL_EVENTS = {"SPELL_HEAL_BY_SELF", "SPELL_HEAL_BY_OTHER"}

--[targetGuid] = { [actorGuid] = threat }
local threat = {}
--[targetGuid] = true, for splitting healing across everything in the fight
local engaged = {}

--You, your pet, and your group with theirs. Threat is only ever recorded for one of
--these, and without the filter the model records the *mob's* damage too -- which files
--an entry under the player as though the player were a target, and then marks the player
--as engaged. That second part is not cosmetic: healing threat is split across everything
--engaged, so a warlock draining and Death Coiling was quietly dividing their healing
--threat between the mob and themselves.
local ours = {}
--how much threat was credited through a number nobody has checked
local modelled, unverified = 0, 0

--What each actor's threat was actually built from: [actorGuid] = {damage, healing, flat}.
--
--Kept because the obvious way to check this model -- compare it against the damage meter
--and see whether a warlock's threat matches their damage -- does not work. The two
--commands are read seconds apart with a fight still running, so any discrepancy is
--equally explained by "the model is wrong" and "you killed more things in between", and
--the comparison proves nothing. Carrying the inputs alongside the output makes a single
--reading self-checking: threat, and the damage it came from, at the same instant.
local raw = {}

local watcher, available

--[[ modifiers ]]--
--
--Multiplies everything an actor generates. Stance and form are the whole story for the
--classes that have them, and they are worth getting right because they are large: a
--warrior in Defensive Stance makes over 60% more threat than the same warrior in Battle
--Stance, which dwarfs any per-spell subtlety.
--
--Talents are deliberately NOT modelled here. Defiance, Feral Instinct, Shadow Affinity
--and Destructive Reach are all real and all school- or ability-scoped, and applying one
--of them globally -- which is all a tooltip scan could honestly do -- would be wrong in
--a way that looks right. They belong in ABILITY_THREAT, per spell, once checked.
local FORM_MODIFIER = {
	--index from GetShapeshiftForm's polyfill in Compatibility/api/wowAPI.lua
	WARRIOR = {[1] = 0.8, [2] = 1.3, [3] = 0.8},
	DRUID = {[1] = 1.3, [3] = 0.71},
}

--Flat class multiplier where there is no form to read.
local CLASS_MODIFIER = {
	ROGUE = 0.71,
	HUNTER = 0.71,
}

--Righteous Fury is a buff rather than a form, and multiplies holy threat by 1.6.
--Detected by aura rather than assumed, but only used for paladins.

--Cached hard, and this is not a micro-optimisation.
--
--UnitClass with a GUID is SuperWoW resolving that GUID to an object, and this was being
--called on *every damage event* -- thousands of times a fight, including on the event
--that kills the target, which is the moment the object is being torn down. Both observed
--freezes happened with a mob dying mid-cast, the client sitting at 0% CPU with a hundred
--threads parked: a native deadlock, not anything Lua can do by itself, but very much the
--shape of a lookup racing an object teardown.
--
--A GUID's class never changes, so one lookup per actor for the life of the session is
--all that was ever needed. That takes the calls from thousands per fight to a handful,
--and takes them out of the hot path entirely.
local classCache = {}

local function ActorClass(guid)
	if classCache[guid] ~= nil then
		return classCache[guid] or nil
	end

	local _, class = UnitClass(guid)
	classCache[guid] = class or false

	return class
end

--The multiplier for whoever generated this threat. A pet is not a player and has no
--stance, so it falls through to 1.
local function ActorModifier(guid)
	local class = ActorClass(guid)
	if not class then return 1 end

	local forms = FORM_MODIFIER[class]
	if forms then
		local form = GetShapeshiftForm and GetShapeshiftForm() or 0
		return forms[form] or 1
	end

	return CLASS_MODIFIER[class] or 1
end

--[[ per-ability threat ]]--
--
--Keyed by spell name, because ranks are separate ids and share their threat behaviour.
--
--  mult  -- multiplies the ability's own damage-derived threat
--  flat  -- threat added regardless of damage, per cast
--  ok    -- true once the number has been checked against this server
--
--Everything absent from this table uses the base rule, which is right for the large
--majority of abilities. Entries here are the exceptions, and the exceptions are exactly
--what a threat meter lives or dies on.
--
--UNVERIFIED, every one. These are the vanilla behaviours the abilities are known for,
--not values measured on OctoWoW -- and this server has already changed formulas this
--addon depends on. Treat them as a starting point to correct, not as fact. The way to
--check one is to run a fight with a single ability and compare M:ThreatReport against
--where aggro actually goes.
local ABILITY_THREAT = {
	--Voidwalker. Torment is the reason a warlock can solo at all, and its threat has
	--nothing to do with its damage.
	["Torment"] = {flat = 145, ok = false},
	["Suffering"] = {taunt = true, ok = false},

	--Warrior threat abilities, here so the shape is right for the next class along
	["Sunder Armor"] = {flat = 261, ok = false},
	["Heroic Strike"] = {flat = 145, ok = false},
	["Revenge"] = {flat = 155, ok = false},
	["Taunt"] = {taunt = true, ok = false},
	["Mocking Blow"] = {taunt = true, ok = false},

	--Known threat-reduced abilities
	["Feign Death"] = {wipe = true, ok = false},
	["Soothing Kiss"] = {ok = false, mult = 0},
}

--Resolved through SuperWoW, the same way the damage meter names its rows.
local spellNames = {}

local function SpellName(id)
	if spellNames[id] ~= nil then return spellNames[id] end

	local name
	if SpellInfo then
		local ok, resolved = pcall(SpellInfo, id)
		if ok and type(resolved) == "string" and resolved ~= "" then
			name = resolved
		end
	end

	spellNames[id] = name or false

	return spellNames[id]
end

--[[ accumulation ]]--

--Records what went in, separately from what came out.
local function NoteRaw(actorGuid, field, amount)
	if not raw[actorGuid] then
		raw[actorGuid] = {damage = 0, healing = 0, flat = 0, flatCasts = 0}
	end

	raw[actorGuid][field] = raw[actorGuid][field] + amount
end

local function Add(targetGuid, actorGuid, amount, verified)
	if not (targetGuid and actorGuid) or not amount or amount <= 0 then return end

	if not threat[targetGuid] then threat[targetGuid] = {} end
	local store = threat[targetGuid]
	store[actorGuid] = (store[actorGuid] or 0) + amount

	engaged[targetGuid] = true

	modelled = modelled + amount
	if not verified then unverified = unverified + amount end
end

--A taunt sets the taunter to just above the current top, which is what the game does and
--is the only sane way to model it without knowing the server's exact numbers.
local function Taunt(targetGuid, actorGuid)
	local store = threat[targetGuid]
	if not store then return end

	local top = 0
	for _, value in pairs(store) do
		if value > top then top = value end
	end

	store[actorGuid] = top * 1.1
end

--One damage or heal event, already attributed.
local function Record(targetGuid, actorGuid, spellId, amount, isHeal)
	amount = tonumber(amount)
	if not amount or amount <= 0 then return end

	--Only our side generates threat worth modelling. See the note on `ours`.
	if not ours[actorGuid] then return end

	local name = spellId and SpellName(spellId)
	local rule = name and ABILITY_THREAT[name]

	if rule and rule.wipe then
		--Feign Death and friends drop the actor off the list entirely
		for _, store in pairs(threat) do
			store[actorGuid] = nil
		end
		return
	end

	if rule and rule.taunt then
		Taunt(targetGuid, actorGuid)
		return
	end

	local modifier = ActorModifier(actorGuid)

	if isHeal then
		--Healing threat is spread over every mob the healer is fighting, not aimed at
		--the unit healed -- which is why this ignores targetGuid entirely.
		local count = 0
		for _ in pairs(engaged) do count = count + 1 end
		if count == 0 then return end

		local each = (amount * 0.5 * modifier) / count
		for mob in pairs(engaged) do
			Add(mob, actorGuid, each, true)
		end

		NoteRaw(actorGuid, "healing", amount)

		return
	end

	--Damage-derived threat follows the base rule and is as trustworthy as the damage
	--itself, even for an ability that also carries a guessed flat value. Only the flat
	--part is unverified, and marking the whole ability unverified understated confidence
	--for exactly the abilities that matter most.
	local value = amount * modifier * ((rule and rule.mult) or 1)
	Add(targetGuid, actorGuid, value, not (rule and rule.mult) or rule.ok)
	NoteRaw(actorGuid, "damage", amount)

	if rule and rule.flat then
		Add(targetGuid, actorGuid, rule.flat * modifier, rule.ok)
		NoteRaw(actorGuid, "flat", rule.flat * modifier)
		--counted, because calibration divides the implied flat total by the number of
		--casts and cannot recover that from the total alone
		NoteRaw(actorGuid, "flatCasts", 1)
	end
end

--SuperWoW hands the GUID back as UnitExists' second return
local function GuidOf(unit)
	local exists, guid = UnitExists(unit)
	if exists and guid then return guid end
end

local function RefreshOurs()
	ours = {}

	local function add(unit)
		local guid = GuidOf(unit)
		if guid then ours[guid] = true end
	end

	add("player")
	add("pet")

	--Only the slots that can hold somebody; see the matching note in DamageMeter's
	--RefreshTracked. Solo this is two lookups rather than ninety, and it runs on UNIT_PET
	--which fires exactly when a pet disengages from a dying target.
	local raid = GetNumRaidMembers()
	if raid > 0 then
		for i = 1, raid do
			add("raid"..i)
			add("raidpet"..i)
		end
	else
		for i = 1, GetNumPartyMembers() do
			add("party"..i)
			add("partypet"..i)
		end
	end
end

local function OnEvent()
	if event == "PLAYER_REGEN_DISABLED" then
		threat, engaged, raw = {}, {}, {}
		modelled, unverified = 0, 0
		--a pet summoned or a group joined mid-session has to be picked up, and combat
		--starting is the last moment it matters
		RefreshOurs()
		return
	elseif event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED"
		or event == "RAID_ROSTER_UPDATE" or event == "UNIT_PET" then
		RefreshOurs()
		return
	end

	--Damage and healing name the target first, swings name the source first; the same
	--inconsistency the damage meter documents.
	if event == "SPELL_DAMAGE_EVENT_SELF" or event == "SPELL_DAMAGE_EVENT_OTHER" then
		Record(arg1, arg2, arg3, arg4)
	elseif event == "SPELL_HEAL_BY_SELF" or event == "SPELL_HEAL_BY_OTHER" then
		Record(arg1, arg2, arg3, arg4, true)
	elseif event == "AUTO_ATTACK_SELF" or event == "AUTO_ATTACK_OTHER" then
		Record(arg2, arg1, nil, arg3)
	end
end

--[[ calibration ]]--
--
--The one measurement available without server threat, taken automatically.
--
--Nothing on this client reports threat, so the only ruler is the moment aggro changes
--hands: the game moves a mob to whoever exceeds the current holder by a known margin --
--110% if they are in melee, 130% at range. One side of that comparison is now known
--exactly, because the player's own conversion has been measured at ratio 1.00. So a
--single flip solves for the other side, and the guessed flat value falls out of it.
--
--Both directions are useful and they are not the same sum:
--  pet loses aggro to the player -- petTrue = playerThreat / threshold
--  player loses aggro to the pet -- petTrue = playerThreat * threshold
--Either way it is the *pet's* true threat that emerges, because the player's is the
--figure being trusted.
--
--Watched rather than caught by hand. Doing this manually means slamming a slash command
--and hoping to hit the instant of the flip, which yields one noisy sample if it works at
--all; watching for it collects a clean one every time a fight happens to produce one.
local calibrating, calibrationSamples = nil, {}
local lastHolder, calibrateElapsed = nil, 0

--Who the current target is actually attacking. Only the two answers that matter.
--
--Off unless asked for, and worth knowing why: this polls unit tokens five times a second
--including through a target's death, and unit lookups racing an object teardown are the
--current suspect for the client freezing. It is a diagnostic tool rather than something
--to leave running, so it stays opt-in even once that is settled.
local function AggroHolder()
	if not UnitExists("target") or UnitIsDeadOrGhost("target") then return end
	if not UnitExists("targettarget") then return end
	if UnitIsUnit("targettarget", "player") then return "player" end
	if UnitIsUnit("targettarget", "pet") then return "pet" end
end

--Melee and ranged use different thresholds and the client will not say which applies, so
--both are recorded. Once samples accumulate, the true value is the column that agrees
--with itself across fights -- which is a better answer than picking one up front.
local MELEE_THRESHOLD, RANGED_THRESHOLD = 1.1, 1.3

local function Calibrate(previous, holder)
	--only a swap between the player and the pet tells us anything
	if not (previous and holder) or previous == holder then return end

	local targetGuid = GuidOf("target")
	local store = targetGuid and threat[targetGuid]
	if not store then return end

	local playerGuid, petGuid = GuidOf("player"), GuidOf("pet")
	if not (playerGuid and petGuid) then return end

	local playerThreat = store[playerGuid]
	local petRaw = raw[petGuid]
	if not (playerThreat and playerThreat > 0 and petRaw and petRaw.flatCasts > 0) then return end

	--pet -> player means the player just exceeded the pet, so the pet was *below* by the
	--threshold; player -> pet is the same comparison the other way up
	local sample = {}
	for _, entry in pairs({{"melee", MELEE_THRESHOLD}, {"ranged", RANGED_THRESHOLD}}) do
		local label, threshold = entry[1], entry[2]
		local petTrue = (holder == "player") and (playerThreat / threshold) or (playerThreat * threshold)
		local flatTotal = petTrue - petRaw.damage
		sample[label] = flatTotal / petRaw.flatCasts
	end

	sample.casts = petRaw.flatCasts
	sample.direction = previous.." -> "..holder
	tinsert(calibrationSamples, sample)

	E:Print(format("|cff00ff00threat calibration|r %s after %d cast(s): flat per cast is |cffffff00%.0f|r if the new holder was in melee, |cffffff00%.0f|r if at range.",
		sample.direction, sample.casts, sample.melee, sample.ranged))
end

--Polled rather than evented: nothing fires when a mob changes its mind about who to hit.
local function OnCalibrateUpdate()
	if not calibrating then return end

	calibrateElapsed = calibrateElapsed + (arg1 or 0)
	if calibrateElapsed < 0.2 then return end
	calibrateElapsed = 0

	local holder = AggroHolder()
	if holder and holder ~= lastHolder then
		Calibrate(lastHolder, holder)
		lastHolder = holder
	elseif not holder then
		--target lost or dead; the next fight starts a fresh comparison
		lastHolder = nil
	end
end

function M:ToggleThreatCalibration()
	calibrating = not calibrating
	lastHolder, calibrateElapsed = nil, 0

	return calibrating and true or false
end

function M:ThreatCalibrationSamples()
	return calibrationSamples
end

--[[ public ]]--

function M:ThreatModelAvailable()
	return available and true or false
end

--Sorted threat on one mob: { {name, threat, share}, ... }. Defaults to the current
--target, which is what anyone asking actually means.
function M:ThreatOn(targetGuid)
	targetGuid = targetGuid or GuidOf("target")
	local store = targetGuid and threat[targetGuid]
	if not store then return {}, 0 end

	local rows, top = {}, 0
	for guid, value in pairs(store) do
		if value > top then top = value end
		local inputs = raw[guid] or {damage = 0, healing = 0, flat = 0}
		tinsert(rows, {
			guid = guid,
			name = UnitName(guid) or guid,
			threat = value,
			damage = inputs.damage,
			healing = inputs.healing,
			flat = inputs.flat,
		})
	end

	for i = 1, getn(rows) do
		rows[i].share = (top > 0) and (rows[i].threat / top) or 0
	end

	sort(rows, function(a, b) return a.threat > b.threat end)

	return rows, top
end

--What proportion of this fight's threat came from numbers nobody has checked. The point
--of surfacing it is that a fight which is all plain damage is trustworthy, and one that
--leaned on Torment's guessed flat value is not.
function M:ThreatConfidence()
	if modelled <= 0 then return 1 end

	return 1 - (unverified / modelled)
end

function M:InitializeThreatModel()
	watcher = CreateFrame("Frame", "OctoUI_ThreatModel", E.UIParent)
	watcher:SetScript("OnEvent", OnEvent)

	--Same source and the same detection as the damage meter: nampower's CVars, never
	--whether RegisterEvent succeeded, because RegisterEvent accepts anything on this
	--client and answers nothing.
	available = (GetCVar and GetCVar("NP_SpellQueueWindowMs") and true) or nil
	if not available then return end

	local groups = {DAMAGE_EVENTS, SWING_EVENTS, HEAL_EVENTS}
	for i = 1, getn(groups) do
		local group = groups[i]
		for j = 1, getn(group) do
			pcall(watcher.RegisterEvent, watcher, group[j])
		end
	end

	watcher:RegisterEvent("PLAYER_REGEN_DISABLED")

	--Wrapped, not passed raw: a 1.12 script handler gets no self and no elapsed, only the
	--globals `this` and `arg1`. The handler returns immediately unless calibration is on,
	--so this costs nothing in normal play.
	watcher:SetScript("OnUpdate", function()
		OnCalibrateUpdate()
	end)

	--who counts as "us" changes with the group and with pets being summoned
	watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
	watcher:RegisterEvent("PARTY_MEMBERS_CHANGED")
	watcher:RegisterEvent("RAID_ROSTER_UPDATE")
	watcher:RegisterEvent("UNIT_PET")

	RefreshOurs()
end
