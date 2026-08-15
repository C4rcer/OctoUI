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
if not OctoWarlockDots then
	OctoWarlockDots = {"Corruption", "Curse of Agony", "Siphon Life", "Curse of Shadow"}
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
		for i = 1, table.getn(OctoWarlockDots) do
			if not OctoMyDebuff(OctoWarlockDots[i]) then return false end
		end

		return true
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
