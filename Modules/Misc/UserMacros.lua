--[[
	YOUR LUA. Edit this file in a text editor, then /reload.

	This is the practical way to keep macro logic on this client. A macro is 255 characters
	and cannot hold a function, and the options page is a poor place to write one because
	1.12 has no clipboard paste -- every line would have to be typed by hand into an in-game
	edit box. A file is edited with a real editor and picked up by /reload.

	Anything defined here is a global, so a macro calls it directly:

		/run WarlockPriority()

	OctoUI does not write to this file, so it survives updates. The options page at
	General - Lua Macros still exists for snippets you want to edit in game, and both run.

	NOTHING HERE IS DEFINED IF SOMETHING ELSE ALREADY DEFINED IT. Every function below is
	wrapped in `if not X then`, so an addon of yours that already provides one keeps it and
	nothing is silently replaced.
]]

--[[
	LEAVE THIS BLOCK AND THE ONE AT THE BOTTOM ALONE.

	Together they work out what this file defined, so the game can TELL you it is loaded --
	the options page lists every function by name and /octoui-lua prints them. Without that
	the only way to know your code is live is to try it and see, which is exactly the
	problem a file was supposed to solve.

	It works by noting which globals exist before your code runs and which exist after; the
	difference is yours. Write your functions between the two blocks.
]]
local _globalsBefore = {}
for name in pairs(_G) do
	_globalsBefore[name] = true
end

--[[
	RANGE FOR A /run MACRO, so its button can colour and glow like a spell button.

	A /cast macro resolves to a spell and OctoUI reads that spell's range. `/run
	WarlockPriority()` resolves to nothing -- which spell it casts is decided inside Lua at
	the moment you press it -- so the range has to be stated here.

	The key is the MACRO's name as it appears in the macro list, not the function's, and the
	value is yards. A macro with no entry here behaves exactly as before: no range colouring.
]]
if not OctoUI_MacroRange then
	OctoUI_MacroRange = {
		--["Priority"] = 30,
	}
end

--[[ helpers ]]--

--True while the player carries a buff whose icon path contains `match` (lowercase).
--
--Textures rather than names because reading a buff's NAME on this client means a tooltip
--scan, and an icon path is one call. The same approach AutoDismount uses to recognise
--shapeshift forms.
if not OctoHasBuffTexture then
	function OctoHasBuffTexture(match)
		local n = 0
		while true do
			local id = GetPlayerBuff(n, "HELPFUL")
			local texture = id and GetPlayerBuffTexture(id)
			if not texture then return false end
			if string.find(string.lower(texture), match) then return true end
			n = n + 1
		end
	end
end

--The spellbook slot for a spell name, looked up fresh every time.
--
--NOT CACHED, deliberately. Spellbook indices shift every time you learn anything, and a
--cached one then points at a different spell -- that is the bug that had Necrosis casting
--the wrong spell off its own buttons. The loop is short and only runs on a keypress.
if not OctoSpellSlot then
	function OctoSpellSlot(name)
		local i = 1
		while true do
			local spell = GetSpellName(i, "spell")
			if not spell then return nil end
			if spell == name then return i end
			i = i + 1
		end
	end
end

--Is this spell off cooldown?
--
--GetSpellCooldown wants a SLOT, not a name, on this client -- every other addon here passes
--one. It also reports the global cooldown like any other cooldown, so for a second and a
--half after any cast every spell reads as unavailable; anything at or under the GCD is
--treated as ready, which is what the macro addons do too.
if not OctoSpellReady then
	function OctoSpellReady(name)
		local slot = OctoSpellSlot(name)
		if not slot then return false end

		local start, duration = GetSpellCooldown(slot, "spell")
		if not start or not duration then return false end
		if duration <= 1.5 then return true end

		return start == 0 and duration == 0
	end
end

--[[ warlock ]]--

--The dots the priority below waits for. Edit this list to change what it gates on; the
--names must match what the game calls them, which /octoui-dots prints for your target.
--
--CURSE OF SHADOW USED TO BE IN HERE and was moved out on 2026-09-04. Every one of these
--must be MINE for the gate to open, and in a raid the curse very often is not: Multidot
--now takes Curse of the Elements when another warlock already holds Shadow, so demanding
--Shadow specifically meant Dark Harvest could never fire for the rest of that fight. The
--curse half moved to its own list below, where either one counts.
if not OctoWarlockDots then
	OctoWarlockDots = {"Corruption", "Curse of Agony", "Siphon Life"}
end

--The curse half of the gate: ANY ONE of these being mine satisfies it.
--
--Shadow and Elements are interchangeable for this purpose because the thing being asked
--is "is my setup on this mob complete", and which of the two you ended up with is decided
--by whichever warlock got there first, not by you.
--
--ASSUMPTION WORTH CHECKING, and easy to revert if wrong: that Dark Harvest does not care
--WHICH curse is yours. If it turns out to need Shadow specifically, put "Curse of Shadow"
--back in OctoWarlockDots above and empty this list -- the gate then behaves exactly as it
--did before. Nothing else depends on this split.
if not OctoWarlockCurses then
	OctoWarlockCurses = {"Curse of Shadow", "Curse of the Elements"}
end

--Is this debuff on the target, and is it MINE?
--
--Asks OctoUI's own debuff tracker rather than a macro addon's. That was the whole problem
--with the conditional version: SuperCleveRoidMacros keeps its own table, it is empty on
--this setup without pfUI, and an empty table makes [debuff:X] always false while making
--[nodebuff:X] always TRUE -- which reads exactly like a working macro.
--
--This one is the same source the nameplate timers use, and /octoui-dots showed it holding
--all four with the right durations and ownership.
if not OctoMyDebuff then
	function OctoMyDebuff(name)
		if not UnitExists("target") then return false end

		local engine = _G.ElvUI and _G.ElvUI[1]
		local NP = engine and engine.GetModule and engine:GetModule("NamePlates", true)
		local lib = NP and NP.LibDebuff
		if not lib then return false end

		--SuperWoW returns the GUID as UnitExists' second value; the store prefers that key
		--because a name is shared by every mob of that type.
		local _, guid = UnitExists("target")
		local _, timeleft, caster = lib:GetTimeLeft(UnitName("target"), UnitLevel("target"), name, guid)

		--Ownership matters: "four of MY dots". With a second warlock on the mob the tracker
		--reports nil rather than claiming theirs is yours, so this stays honest and the
		--gate simply will not open -- drop the caster test if you would rather it did.
		return (timeleft and timeleft > 0 and caster == "player") and true or false
	end
end

if not OctoAllDotsUp then
	function OctoAllDotsUp()
		local total = table.getn(OctoWarlockDots)
		--An empty list would otherwise pass vacuously -- "all zero of them are up" -- and
		--open the gate permanently. That exact shape is what made the conditional macro look
		--like it worked for a week.
		if total == 0 then return false end

		for i = 1, total do
			if not OctoMyDebuff(OctoWarlockDots[i]) then return false end
		end

		--The curse half. Any one of them being mine will do; see OctoWarlockCurses.
		--
		--An EMPTY list passes, unlike the dots above, and the difference is deliberate.
		--Emptying the dot list would open the gate vacuously and permanently, which is the
		--bug the comment up there records. Emptying this one is how you say "I do not want
		--the gate to care about curses at all", which is a real thing to want -- so it has
		--to mean no requirement rather than an impossible one.
		local curses = OctoWarlockCurses and table.getn(OctoWarlockCurses) or 0
		if curses == 0 then return true end

		for i = 1, curses do
			if OctoMyDebuff(OctoWarlockCurses[i]) then return true end
		end

		return false
	end
end

--What the gate thinks, dot by dot. Run it with the mob targeted: /run OctoDotReport()
if not OctoDotReport then
	function OctoDotReport()
		local out = DEFAULT_CHAT_FRAME
		out:AddMessage("Dot gate -- target: "..tostring(UnitName("target")))

		for i = 1, table.getn(OctoWarlockDots) do
			local name = OctoWarlockDots[i]
			out:AddMessage("  "..name.." = "..tostring(OctoMyDebuff(name)))
		end

		--The curses are listed too, and marked, because they are the half that fails in a
		--raid: any ONE of them being mine opens the gate, so a report showing only the dots
		--would say every line is true and leave the closed gate unexplained. This IS the
		--tool for that question -- it must not go quiet about the part that moved.
		local curses = OctoWarlockCurses and table.getn(OctoWarlockCurses) or 0
		for i = 1, curses do
			local name = OctoWarlockCurses[i]
			out:AddMessage("  "..name.." = "..tostring(OctoMyDebuff(name)).." (any one of these)")
		end
		if curses == 0 then
			out:AddMessage("  no curse required -- OctoWarlockCurses is empty")
		end

		out:AddMessage("  all mine = "..tostring(OctoAllDotsUp())
			.. ", Dark Harvest ready = "..tostring(DHReady()))
	end
end

--Nightfall's proc, which makes the next Shadow Bolt instant. Spell_Shadow_Twilight is its
--icon; change the string if this realm uses another.
if not STReady then
	function STReady()
		return OctoHasBuffTexture("spell_shadow_twilight")
	end
end

if not DHReady then
	function DHReady()
		return OctoSpellReady("Dark Harvest")
	end
end

--[[
	Spend a Nightfall proc first, then Dark Harvest once all four dots are up and it is off
	cooldown, then Drain Soul.

	THE PROC GOES FIRST because it does not queue. Nightfall rolls off your Corruption and
	Drain Life ticks, and a proc that lands while one is already sitting there is simply
	lost -- so holding it for a global cooldown risks throwing the next one away. Dark
	Harvest's cooldown, by contrast, is still there a moment later.
]]
if not WarlockPriority then
	function WarlockPriority()
		if STReady() then
			CastSpellByName("Shadow Bolt")
			return
		end

		if OctoAllDotsUp() and DHReady() then
			CastSpellByName("Dark Harvest")
			return
		end

		CastSpellByName("Drain Soul")
	end
end

--[[
	THE CURSE QUEUE, in one place because two buttons need exactly the same answer.

	Multidot and Singledot both have to ask "which curse should I put on this mob", and
	the moment that logic exists twice it starts drifting -- the Elements step was added
	to one of them first and the other went on skipping straight to Agony. So the order
	lives here and both call it.

	SHADOW, THEN ELEMENTS, THEN AGONY. A mob holds one Curse of Shadow AND one Curse of
	the Elements -- one of each, not one between them -- and a raid wants both up. So the
	two big curses are a queue: take Shadow if nobody has it, take Elements if somebody
	does, and if two other warlocks have already taken both then there is no big curse
	left to place and Agony is what remains.

	IT WORKS BECAUSE CURSIVE SEES OTHER PEOPLE'S CURSES, which is not obvious and is why
	no extra detection was needed. Cursive:Curse defers to curses:HasCurse, which reads
	curses.guids[guid][name] without looking at who cast it, and that table is filled both
	by ApplyCurse for your own casts (currentPlayer = true) and by a UnitDebuff scan for
	everybody else's (currentPlayer = false -- Cursive's own localisation calls those
	"Shared Curse of Shadow" and "Shared Curse of the Elements"). Both curses are in its
	tracked spell tables at every rank.

	So the Shadow line already returned false when another warlock held Shadow. It simply
	had nothing to fall through to.

	Preferred over OctoUI's own lib:Contested for this: that infers from a cast event with
	a deliberately generous 300s window and keeps calling a curse contested long after it
	fell off. This is a scan of what is actually on the mob.

	The name is "Curse of the Elements", with the "the". Cursive's spell tables and
	Settings/DebuffDurations both spell it that way; "Curse of Elements" matches nothing
	and would cast nothing at all, silently.

	Returns true when it cast something, exactly as Cursive:Curse does, so a caller can
	chain the rest of its dots behind it.
]]
--The two curses that compete for your ONE curse slot on a mob. Kept separate from
--OctoWarlockCurses even though they hold the same names today: that one is the Dark
--Harvest gate and is documented as safe to empty ("I do not want the gate to care about
--curses"), and emptying it must not quietly disable the loop guard below.
local BIG_CURSES = {"Curse of Shadow", "Curse of the Elements"}

--Cursive keys its table by GUID. Cursive:Curse resolves "target" for itself, but reading
--the table directly needs the GUID in hand, so the same resolution happens here.
local function CurseGuid(target)
	if not target then return nil end
	if string.sub(target, 1, 2) == "0x" then return target end

	local _, guid = UnitExists(target)
	return guid
end

--The record Cursive holds for this curse on this mob, whoever cast it. Its keys are the
--lowercased, rank-stripped spell name, which is what Cursive:Curse looks up too.
--The form Cursive stores a spell name in: lowercased, rank stripped. Both the guids table
--and trackedCurseIds use it, so anything comparing against either has to go through here.
local function CurseKey(spellName)
	return (Cursive and Cursive.utils and Cursive.utils.GetLowercaseSpellNameNoRank
		and Cursive.utils.GetLowercaseSpellNameNoRank(spellName)) or string.lower(spellName)
end

local function CurseEntry(guid, spellName)
	local tracker = Cursive and Cursive.curses
	if not (guid and tracker and tracker.guids) then return nil end

	local store = tracker.guids[guid]
	return store and store[CurseKey(spellName)]
end

--[[
	OUR OWN CASTS, TRACKED HERE, because Cursive's ownership flag is wrong for these two.

	MEASURED 2026-09-04 with /run OctoCurseReport(), solo, on a mob nobody else had touched:

	    store [curse of agony]        currentPlayer=true   remaining=18
	    store [curse of the elements] currentPlayer=false  remaining=298.423

	298.4 of 300 means that Elements had been cast 1.6 seconds earlier, by the player, and
	Cursive had it marked as NOT the player's. Agony on the same mob is marked correctly.
	The difference is the path: Agony is recorded by ApplyCurse, while the two big curses
	arrive through Cursive's shared-debuff scan, which builds records with
	currentPlayer = false whoever cast them.

	That single flag is what three attempts at this were built on, and it is why each one
	looped. Cast Shadow, Cursive files it as somebody else's, the chain reads "another
	warlock has Shadow", casts Elements over it, Shadow is gone, repeat forever.

	So ownership is kept here instead. It cannot disagree with itself: nothing writes it but
	our own cast, and one curse per warlock means one entry per mob is the whole truth.

	EXPIRY IS OUR OWN TOO. A curse of ours that has run out must stop counting or the chain
	would never recast it, so the record carries the moment it can no longer be up. The
	table is keyed by GUID and never grows without bound in practice, but it is pruned on
	write anyway -- a long session across many mobs should not accumulate one entry per mob
	ever cursed, which is the shape HANDOFF item 12c records for the debuff store.
]]
local CURSE_DURATION = 300
local ownCurse = {}

local function RememberOwnCurse(guid, spellName)
	if not guid then return end

	local now = GetTime()

	--Pruned on write rather than on a timer: anything that expired a curse ago is gone
	--whatever mob it belonged to.
	for key, record in pairs(ownCurse) do
		if record.expires < now then ownCurse[key] = nil end
	end

	ownCurse[guid] = {name = CurseKey(spellName), expires = now + CURSE_DURATION}
end

--Which of the two big curses is OURS on this mob, or nil. Cross-checked against Cursive's
--store: if the curse is no longer on the mob at all, ours is not either, whatever our
--record says -- dispels, deaths and a second warlock overwriting us all end it early.
local function OwnBigCurse(guid)
	local record = guid and ownCurse[guid]
	if not record then return nil end

	if record.expires < GetTime() then
		ownCurse[guid] = nil
		return nil
	end

	local tracker = Cursive and Cursive.curses
	local store = tracker and tracker.guids and tracker.guids[guid]
	local entry = store and store[record.name]

	if not (entry and tracker:TimeRemaining(entry) > 0) then
		ownCurse[guid] = nil
		return nil
	end

	return record.name
end

--[[
	ONE CURSE PER WARLOCK, and that is the whole shape of this.

	A MOB holds one Curse of Shadow and one Curse of the Elements. A WARLOCK holds one
	curse: the second replaces the first. So the pair on a mob comes from two different
	warlocks, which is the raid case this exists for, and the choice here is one curse
	rather than a list to walk.

	If one of them is already ours, the other one is not available -- casting it would take
	our own down. Cursive is still asked, so a curse of ours inside its refresh window gets
	renewed rather than abandoned, but only ever the one we already hold.

	With nothing of ours on the mob: Shadow if it is free, Elements if it is not. "Not
	free" can only mean another warlock here, because our own is accounted for above.

	Agony sits outside the pair. Malediction puts it up alongside Shadow, so it does not
	compete for the slot, and it is what remains when both big curses are taken.

	The name is "Curse of the Elements", with the "the". Cursive's spell tables and
	Settings/DebuffDurations both spell it that way; "Curse of Elements" matches nothing
	and casts nothing, silently.
]]
local function CurseChain(target)
	local guid = CurseGuid(target)
	local held = OwnBigCurse(guid)

	if held then
		--Ours. Renew it if Cursive says it is due, otherwise fall through to Agony. Never
		--the other one: that would replace what we are holding.
		for i = 1, table.getn(BIG_CURSES) do
			if CurseKey(BIG_CURSES[i]) == held then
				if Cursive:Curse(BIG_CURSES[i], target, {refreshtime = 1}) then
					RememberOwnCurse(guid, BIG_CURSES[i])
					return true
				end
				break
			end
		end
	else
		--Nothing of ours here. Shadow first; if it will not go on, somebody else has it and
		--Elements is the half of the pair still going spare.
		if Cursive:Curse("Curse of Shadow", target, {refreshtime = 1}) then
			RememberOwnCurse(guid, "Curse of Shadow")
			return true
		end

		if Cursive:Curse("Curse of the Elements", target, {refreshtime = 1}) then
			RememberOwnCurse(guid, "Curse of the Elements")
			return true
		end
	end

	if Cursive:Curse("Curse of Agony", target, {refreshtime = 1}) then return true end

	return false
end

--[[
	WHAT THE CURSE CHAIN CAN SEE, for when it picks the wrong one.

	Every wrong answer this has given came from a disagreement between what Cursive holds
	and what the chain believed it held, and none of it is visible from the outside -- the
	symptom is a curse landing, which looks the same whichever branch chose it. Run this
	with the mob targeted, right after a press that did the wrong thing:

		/run OctoCurseReport()

	The store listing is the important part. It prints the keys Cursive actually holds, so
	a name that does not match -- the wrong lowercase form, a rank left on, a localisation
	difference -- shows up as an entry present in the store and MISSING on the lookup line.
]]
if not OctoCurseReport then
	function OctoCurseReport()
		local out = DEFAULT_CHAT_FRAME

		if not (Cursive and Cursive.curses) then
			out:AddMessage("OctoCurseReport: Cursive is not loaded.")
			return
		end

		local tracker = Cursive.curses
		local guid = CurseGuid("target")

		out:AddMessage("Curse chain -- target: "..tostring(UnitName("target"))
			..", guid = "..tostring(guid))

		local store = guid and tracker.guids and tracker.guids[guid]
		if store then
			for key, entry in pairs(store) do
				out:AddMessage("    store ["..tostring(key).."] currentPlayer="
					..tostring(entry.currentPlayer)
					.." remaining="..tostring(tracker:TimeRemaining(entry)))
			end
		else
			out:AddMessage("    store: no entry for this mob")
		end

		local pending = tracker.pendingCast
		if pending and pending.spellID then
			local tracked = tracker.trackedCurseIds and tracker.trackedCurseIds[pending.spellID]
			out:AddMessage("    pendingCast: name="..tostring(tracked and tracked.name)
				..", onThisMob="..tostring(pending.targetGuid == guid))
		else
			out:AddMessage("    pendingCast: none")
		end

		for i = 1, table.getn(BIG_CURSES) do
			local name = BIG_CURSES[i]
			out:AddMessage("  "..name.." -> key '"..tostring(CurseKey(name)).."', lookup "
				..(CurseEntry(guid, name) and "found" or "MISSING"))
		end

		--The line that actually decides, and the one Cursive cannot answer: currentPlayer
		--reads false for the player's own Shadow and Elements, which is what sent three
		--earlier versions of the chain into a loop.
		out:AddMessage("  ours on this mob = "..tostring(OwnBigCurse(guid))
			.." (tracked here, not by Cursive -- its currentPlayer is false for both)")
	end
end

--[[
	MULTI-DOT, through Cursive.

	One button that keeps Curse of Shadow, Corruption and Siphon Life rolling on every
	mob in combat WITHOUT changing your target. Cursive:Multicurse picks the target
	itself, casts, and returns true; false means every mob already has that dot fresh
	enough, so the next spell down gets a turn.

	IT IS HERE RATHER THAN IN A MACRO FOR ONE REASON: 1.12 has no clipboard paste. The
	chained version fits inside the 255 character macro limit at 237, so length is not
	the obstacle -- but getting 237 characters into the macro editor means typing every
	one of them by hand, correctly, including the braces and the quotes. A file is
	edited with a real editor. That is the whole point of this file.

	The macro becomes:

		/run Multidot()

	`refreshtime` is a Cursive option, in seconds: it allows a re-cast when that much
	time or less is left. Corruption gets 3 because it is the longest of the three and
	worth refreshing early; the other two get 1.

	ORDER IS PRIORITY, and a missing curse is the most valuable global. Change the order
	in CurseChain above rather than here or in the macro.

	CORRECTED 2026-09-04: this used to say "only one curse can sit on a mob at a time",
	which is wrong and had the feature pointed the wrong way. A mob holds one of EACH
	curse -- one Shadow and one Elements -- so a second warlock does not overwrite the
	first, they take the other one. That is the whole basis of the Elements step.
]]
--[[
	IT MUST NOT PULL, and by default it does.

	Cursive decides a mob is eligible like this (commands.lua, pickTarget):

		if ignoreInFight or Cursive.filter.infight(guid) or guid == currentTargetGuid then

	The last clause is the problem. Your CURRENT TARGET is always eligible whether or
	not it is fighting anybody, so pressing this with an unengaged aggressive mob
	targeted dots it and pulls it. That is Cursive's behaviour and it applies to the
	plain chained macro exactly as it does here.

	`ignoretarget` on its own is too blunt: the line ABOVE that one reads

		if not options["ignoretarget"] or guid ~= currentTargetGuid then

	which drops the current target from consideration entirely, so your real target
	would stop receiving dots as well.

	So it is applied CONDITIONALLY -- only while the target is not in combat. Then the
	only clause an idle mob could have qualified under is gone, and the moment your
	target is actually fighting it qualifies on its own merits and comes back in. No
	behaviour is lost; only pulling is.
]]
--[[
	PICKING THE MOBS OURSELVES, because neither of Cursive's two answers is the one
	wanted here and both have now been measured failing.

	With Cursive's "In Combat" filter ON, a mob is gated on UnitAffectingCombat(guid),
	which does not answer for anything except your current target on this client. The
	measured result was a linked pair where spamming the button dotted only the mob that
	was targeted, then moved on when it died.

	With that filter OFF there is no combat test at all, and the measured result was dots
	landing on two NEUTRAL mobs standing near the fight -- which pulls them.

	THE POOL CARRIES A BETTER SIGNAL THAN EITHER. Cursive.core.guids maps a guid to the
	last time it was seen, refreshed from UNIT_COMBAT (core.lua) -- an actual combat event
	on that unit. Anything swinging at anybody refreshes constantly. An idle mob never
	does: it is in the pool only because it was targeted or moused over once, and its
	timestamp stops dead there.

	So the test becomes "seen in a combat event within the last few seconds", derived from
	events that really happened rather than from a call that does not answer.

	AND HOSTILE ONLY. Cursive's attackable filter passes a neutral mob, because you *can*
	attack it -- that is what let the boar through. UnitIsEnemy is false for a neutral mob
	until it is actually fighting you, so it is the test that says "already my enemy"
	rather than "could be made one".

	Three conditions, each closing a hole the other two cannot:

		hostile   - never dots a yellow mob, so it can never make one
		recent    - never dots an idle red mob standing near the fight
		in combat - the guard in Multidot; never opens a fight at all

	Cursive still does the rest. ShouldDisplayGuid applies its exists / alive / attackable
	/ not-mind-controlled filtering, and Cursive:Curse applies refreshtime, the
	crowd-control check and the cast. Only the CHOICE of mob is ours.

	Cursive's own "In Combat" filter should stay OFF. It would re-apply the
	UnitAffectingCombat test inside ShouldDisplayGuid and put us back to target-only.
]]
local COMBAT_RECENCY = 5

--Highest health first, matching the HIGHEST_HP priority this replaces.
local function ByHealth(a, b)
	return (UnitHealth(a) or 0) > (UnitHealth(b) or 0)
end

--[[
	GIVING CURSIVE THE MOBS, because it cannot see them on its own.

	Measured, not reasoned: with a linked pair beating on the player, Cursive.core.guids
	held the target and a corpse. The second Centurion was never in the pool at all, so
	every filter argued about above was irrelevant -- there was nothing to filter.

	Cursive acquires from three places (core.lua): PLAYER_TARGET_CHANGED, UNIT_COMBAT and
	UNIT_MODEL_CHANGED. The first is your target. The second carries a unit TOKEN, and a
	mob nobody has targeted has no token. So in a raid the pool fills up from everyone
	else's targets and multicurse works beautifully; solo it contains your target and
	whatever you happened to mouse over. That is why this macro works for a raiding
	warlock and not here.

	Nameplates already know the pack. SuperWoW names a plate's parent frame after the
	unit's GUID -- the same trick OctoUI's own nameplate castbar uses to map a cast to a
	plate -- so every visible plate is a guid Cursive can be told about. addGuid does its
	own validation: 0x prefix, exists, not dead, and the pool cap.

	This also fixes Cursive's own multicurse as a side effect, since it is the same pool.
]]
local function AcquireFromNameplates()
	if not (ElvUI and Cursive.core and Cursive.core.addGuid) then return end

	local E = unpack(ElvUI)
	local NP = E and E.GetModule and E:GetModule("NamePlates", true)
	local plates = NP and NP.VisiblePlates
	if not plates then return end

	for frame in pairs(plates) do
		local parent = frame:GetParent()
		local guid = parent and parent.GetName and parent:GetName(1)

		if guid and string.sub(guid, 1, 2) == "0x" then
			Cursive.core.addGuid(guid)
		end
	end
end

local function ActiveGuids()
	local candidates = {}

	--Acquire first: a mob that is not in the pool cannot be chosen no matter what the
	--filters below say. This also refreshes the timestamp of everything currently on
	--screen, which is what keeps the recency test meaningful rather than a proxy for
	--"is my target" -- a mob whose plate has gone stops being refreshed and ages out.
	AcquireFromNameplates()

	local guids = Cursive.core and Cursive.core.guids
	if not guids then return candidates end

	local now = GetTime()
	for guid, seen in pairs(guids) do
		if (now - seen) <= COMBAT_RECENCY
			and Cursive.filter.hostile(guid)
			and Cursive:ShouldDisplayGuid(guid)
			--Range, using the check Cursive itself falls back to. A cast at something out
			--of range costs a global and an error message.
			and CheckInteractDistance(guid, 4)
		then
			table.insert(candidates, guid)
		end
	end

	table.sort(candidates, ByHealth)
	return candidates
end

if not Multidot then
	function Multidot()
		--Guarded rather than assumed: without Cursive this is an "attempt to index a nil
		--value" on a button somebody presses in combat.
		if not (Cursive and Cursive.Multicurse) then
			DEFAULT_CHAT_FRAME:AddMessage("Multidot: Cursive is not loaded.")
			return
		end

		--[[
			OUT OF COMBAT THIS DOES NOTHING, and that is the only safe answer.

			Cursive's own combat filter gives up while you are not fighting (filter.lua):

				-- If the player is not in combat, the "In Combat" filter is a no-op
				if not UnitAffectingCombat("player") then return true end

			So out of combat EVERY attackable mob in range is eligible, targeted or not.
			The conditional ignoretarget below closes the "your target is always eligible"
			clause, but with no target at all there is nothing left to exclude and Cursive
			will happily pick the biggest thing nearby and pull it -- which is exactly the
			target-then-untarget case.

			The two guards cover different holes and both are needed: this one for the
			filter going no-op, the one below for the current-target exemption while you
			ARE in combat.

			The cost is that this button cannot open a fight. That is correct for what it
			is -- a button that spreads dots across things already fighting you. Opening is
			a single-target cast.
		]]
		if not UnitAffectingCombat("player") then return end

		local candidates = ActiveGuids()

		--[[
			THE CURSE PAIR GOES FIRST, AND PER MOB. This is the fix for a resisted Agony.

			Malediction ties the two together: applying Curse of Shadows afflicts the
			target with Agony as well, so a mob with Shadow normally has Agony and a
			separate Agony clause looks redundant. It is not -- Agony can resist on its
			own, and then Shadow is still up, so anything that only asks "does this mob
			need Shadow" walks straight past a mob missing half its curse.

			IT ALSO HAS TO BE PER MOB, which is what the first version got wrong. Walking
			spell by spell across every mob spreads Shadow to everything before Agony is
			considered anywhere -- fine on a single target, useless in the case that
			actually matters, because on a boss with adds there is nearly always some mob
			still missing Shadow and the boss's resisted Agony never gets a turn.

			So: for each mob, in health order, make its CURSE whole before moving on. One
			cast either way, and the mob that most needs a curse gets one.
		]]
		for i = 1, table.getn(candidates) do
			local guid = candidates[i]

			--The curse half, shared with Singledot. See CurseChain above.
			if CurseChain(guid) then return end
		end

		--[[
			The remaining dots stay SPELL by spell, deliberately.

			Curses are one-per-mob and worth completing before moving on; Corruption and
			Siphon Life are not. Spreading each of those across everything before starting
			the next is what makes this a multi-dot rather than a rotation that fully dots
			one mob while the rest stand untouched.
		]]
		local spells = {
			{"Corruption", 3},
			{"Siphon Life", 1}
		}

		for spellIndex = 1, table.getn(spells) do
			local spell, refresh = spells[spellIndex][1], spells[spellIndex][2]

			for i = 1, table.getn(candidates) do
				if Cursive:Curse(spell, candidates[i], {refreshtime = refresh}) then return end
			end
		end
	end
end

--[[
	SINGLE TARGET, the counterpart to Multidot.

	Same dots, same priority, on the mob you actually have targeted. This is the one to
	press on a boss; Multidot is the one to press when a pack needs spreading.

	The macro becomes:

		/run Singledot()

	Rename the function if your macro is called something else -- it is one line, and
	nothing else refers to it.

	NO COMBAT GUARD, and that is the difference from Multidot rather than an oversight.
	Multidot refuses out of combat because Cursive PICKS ITS OWN TARGET there and will
	happily dot something that is not fighting anybody, which pulls it. This one acts on
	the target you deliberately selected, so opening a fight with it is the point.
]]
if not Singledot then
	function Singledot()
		--Guarded rather than assumed: without Cursive this is an "attempt to index a nil
		--value" on a button somebody presses in combat.
		if not (Cursive and Cursive.Curse) then
			DEFAULT_CHAT_FRAME:AddMessage("Singledot: Cursive is not loaded.")
			return
		end

		--Cursive resolves "target" through UnitExists itself, but it warns rather than
		--returning quietly when there is nothing there, and a button that scolds you for
		--pressing it with no target is noise.
		if not UnitExists("target") then return end

		if CurseChain("target") then return end

		--Corruption gets 3 because it is the longest of these and worth refreshing early;
		--Siphon Life gets 1. Same numbers as Multidot, for the same reasons.
		if Cursive:Curse("Corruption", "target", {refreshtime = 3}) then return end
		Cursive:Curse("Siphon Life", "target", {refreshtime = 1})
	end
end

--[[
	WHICH SIGNAL ACTUALLY SEPARATES TWO MOBS IN THE SAME FIGHT.

	Three attempts have now been made at "is this mob in combat with me" and all three
	were reasoned rather than measured:

		UnitAffectingCombat(guid)   - does not answer except for your current target
		Cursive.core.guids recency  - refreshed from UNIT_COMBAT, which carries a unit
		                              TOKEN, so a mob that is not your target never
		                              refreshes and recency collapses to "is my target"
		threat model `engaged`      - set from OUR damage, so a mob we have not hit yet
		                              is absent, and hitting it first is the whole job

	So stop guessing. Run this with a linked pair on you, one targeted and one not, and
	it prints every candidate signal for every mob Cursive is tracking. Whichever column
	differs between the two mobs is the one to build on -- and if none of them differ,
	that is worth knowing too, because it means the information is not available and the
	honest answer is a button that dots your target and says so.

		/run MultidotDebug()
]]
if not MultidotDebug then
	function MultidotDebug()
		if not (Cursive and Cursive.core and Cursive.core.guids) then
			DEFAULT_CHAT_FRAME:AddMessage("MultidotDebug: Cursive is not loaded.")
			return
		end

		local _, targetGuid = UnitExists("target")
		local now = GetTime()

		--Acquire first so the listing shows what Multidot would actually see, rather than
		--the pool as it stood before the button was pressed.
		AcquireFromNameplates()

		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"MultidotDebug: player in combat = %s", tostring(UnitAffectingCombat("player"))))
		DEFAULT_CHAT_FRAME:AddMessage("name | age | isTarget | affectingCombat | isEnemy | inRange | shouldDisplay")

		local shown = 0
		for guid, seen in pairs(Cursive.core.guids) do
			--Mobs only. The pool also holds the player, pets and party members.
			if UnitExists(guid) and not UnitIsPlayer(guid) then
				shown = shown + 1

				local ok, display = pcall(Cursive.ShouldDisplayGuid, Cursive, guid)

				DEFAULT_CHAT_FRAME:AddMessage(string.format(
					"%s | %.1fs | %s | %s | %s | %s | %s",
					tostring(UnitName(guid)),
					now - seen,
					tostring(guid == targetGuid),
					tostring(UnitAffectingCombat(guid)),
					tostring(UnitIsEnemy("player", guid)),
					tostring(CheckInteractDistance(guid, 4) and true or false),
					tostring(ok and display or "err")))
			end
		end

		if shown == 0 then
			DEFAULT_CHAT_FRAME:AddMessage("  (Cursive is tracking no mobs at all)")
		end
	end
end

--[[
	IS THE PLAYER SWIMMING, and which call is willing to say so.

	Vanilla has no swim state at all. Two of the injected DLLs claim to add one and
	neither addon that uses them guards the call, so neither is evidence that it exists
	on this build:

		IsSwimming()        - ClassicAPI.dll, used unguarded by SuperCleveRoidMacros
		PlayerIsSwimming()  - nampower 2.36+, documented in its own API notes

	Run this on dry land, then again while swimming, and compare. A function that is
	absent prints "missing"; one that is present but always returns the same value in
	both states is present and useless, which is worth knowing before anything is built
	on it.

		/run SwimCheck()

	MirrorTimer is the fallback and is NOT the same question: the breath bar only appears
	when the head is UNDER water, so it cannot tell swimming on the surface from walking
	on the shore. Listed so the difference is visible in the same capture.
]]
if not SwimCheck then
	function SwimCheck()
		local function report(name, fn)
			if type(fn) ~= "function" then
				DEFAULT_CHAT_FRAME:AddMessage(name.." = missing")
				return
			end

			local ok, value = pcall(fn)
			if ok then
				DEFAULT_CHAT_FRAME:AddMessage(name.." = "..tostring(value))
			else
				DEFAULT_CHAT_FRAME:AddMessage(name.." = error: "..tostring(value))
			end
		end

		report("IsSwimming()", IsSwimming)
		report("PlayerIsSwimming()", PlayerIsSwimming)

		--Underwater only, and only while the bar is running.
		if GetMirrorTimerInfo then
			local timer, _, _, _, label = GetMirrorTimerInfo(1)
			DEFAULT_CHAT_FRAME:AddMessage("MirrorTimer 1 = "..tostring(timer)
				.." ("..tostring(label)..")")
		end
	end
end

--[[
	THE OTHER HALF OF THE BLOCK AT THE TOP. Anything you write BELOW this will still work,
	it just will not be listed by name in the options page or by /octoui-lua -- so keep your
	functions above it.
]]
OctoUI_UserMacros = {}
for name, value in pairs(_G) do
	if not _globalsBefore[name] and type(value) == "function" then
		table.insert(OctoUI_UserMacros, name)
	end
end
table.sort(OctoUI_UserMacros)
