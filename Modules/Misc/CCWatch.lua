local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, ipairs, type, tonumber, next = pairs, ipairs, type, tonumber, next
local getn, tinsert, tremove, sort = table.getn, table.insert, table.remove, table.sort
local format, lower, find, tostring = string.format, string.lower, string.find, tostring
--WoW API / Variables
local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitName = UnitName
local UnitExists = UnitExists
local UnitIsDead = UnitIsDead
local UnitDebuff = UnitDebuff
local TargetUnit = TargetUnit

--[[
	A watch list for the things you have crowd controlled.

	1.12 has no focus unit, and the reason this can exist anyway is SuperWoW: a GUID is
	accepted anywhere a unit token is, so UnitName, UnitDebuff and TargetUnit all answer for
	a mob you are not targeting. Cursive-Raid is built on the same foundation.

	WHAT GOES ON THE LIST is decided by UNIT_CASTEVENT, not by watching debuffs appear.
	A cast tells us the caster, the target and the spell in one event, so a fear of yours is
	distinguishable from the other warlock's fear on the same mob -- which is the whole
	point, since re-fearing something somebody else is holding is how a pull comes apart.

	THE PET COUNTS AS YOU. Seduction is cast by the succubus, so its GUID is checked
	alongside the player's; without that the one CC a warlock leans on hardest would never
	appear.

	DURATIONS ARE NOT REDEFINED HERE. LibDebuff already holds a per-rank duration for every
	one of these spells, generated per locale and correct for this realm, and SpellInfo hands
	back the rank that was actually cast. A second table would be one more thing to keep in
	step and would disagree the first time a rank was missed.

	BREAKING EARLY IS THE NORMAL CASE. A feared mob that takes a tick of damage is loose long
	before its timer says so, and a list that keeps counting down is worse than no list. The
	debuff is checked against the mob itself -- by spell id, which SuperWoW returns as
	UnitDebuff's fourth value -- and the row turns red the moment it is no longer there. That
	check is skipped while the client cannot see the mob, because "no data" and "no debuff"
	look identical and reading the first as "it broke" is exactly wrong: a feared mob running
	out of range is when you most want to know how long is left.

	A ROW ONLY LEAVES WHEN THE MOB DIES. Removing it when the control lapsed was the first
	design and it was backwards: the row vanished at the precise moment its one job -- being
	something to click and re-cast on -- mattered most. Losing control changes how the row
	LOOKS, never whether it is there.

	WHICH MEANS DEATH HAS TO BE READ CAREFULLY. UnitIsDead answers for a GUID, but only while
	the client can see the mob at all, and a feared mob is very often out of range. So a row
	goes on a POSITIVE answer only; merely not being visible keeps it. Cursive-Raid learned
	the same thing from the other side and says so in core.lua -- its first attempt evicted
	mobs that were still standing there, and it now keeps anything carrying its own curses.
	A long stale timeout is the only backstop, for the case where the mob is gone and the
	client never says so.
]]

--Single-target crowd control, by the name this locale calls it. AoE fears are deliberately
--absent: UNIT_CASTEVENT carries one target, so a Howl of Terror would put one arbitrary mob
--of five on the list and quietly imply the other four were not feared.
--
--English names, because the duration table they are looked up in is itself keyed by
--localised name and only the enUS one is verified here. /octoui-cc prints this list, so a
--spell that is missing on another locale is at least visible.
local CC_SPELLS = {
	["Fear"] = true,
	["Banish"] = true,
	["Polymorph"] = true,
	["Sap"] = true,
	["Shackle Undead"] = true,
	["Hibernate"] = true,
	["Seduction"] = true,
	["Enslave Demon"] = true,
	["Entangling Roots"] = true,
	["Freezing Trap Effect"] = true,
	["Scare Beast"] = true,
	["Turn Undead"] = true,
	["Repentance"] = true,
	["Blind"] = true,
	["Sleep"] = true,
	["Gouge"] = true,
	["Death Coil"] = true,
	["Mind Control"] = true
}

local ROW_WIDTH, ROW_HEIGHT = 190, 20
local MAX_ROWS = 6
local UPDATE_INTERVAL = 0.05
--The break check walks a mob's debuffs, so it runs a fifth as often as the bars redraw.
local SCAN_INTERVAL = 0.25

--The backstop for a mob that is gone without the client ever saying it died: five minutes
--since it was last visible. Cursive uses the same figure for the same reason, having first
--tried thirty seconds and found it dropped mobs that were still standing in front of you.
local UNSEEN_TIMEOUT = 300

--A row that has been red for a minute on a mob the client cannot even see is not helping
--anyone: it either reset, was killed out of range, or was dealt with by somebody else.
--Loose AND out of sight, both -- a loose mob standing in front of you is exactly the row
--worth keeping.
local LOOSE_TIMEOUT = 60

local function MarkLoose(entry, why)
	if not entry or entry.loose then return end

	entry.loose = why
	entry.looseAt = GetTime()
end

local watch = {}
local rows = {}
local holder, watcher
local lastScan = 0
local lastRemoved
--How many rows are on screen, so the idle path can tell "already cleared" from "needs
--clearing" without touching the rows every frame.
local shownRows = 0

--[[
	What the cast handler has actually seen.

	"Nothing appears" has three completely different causes and they look identical from the
	outside: the event never fires at all (no SuperWoW, so nothing here can work), it fires
	but no cast is being read as yours, or casts are read as yours and the spell simply is
	not on the CC list. These three counters separate them in one line of /octoui-cc, and
	the last few spell names say which spell to add if it is the third.

	Same shape as AutoDismount's record of error strings it did not recognise, for the same
	reason: a list that is silent about what it rejected cannot be debugged from a chair.
]]
local castEvents, ownCasts = 0, 0
local seenCasts = {}

local function NoteCast(name, matched)
	local label = (name or "?")..(matched and "" or " |cff888888(not CC)|r")

	for i = 1, getn(seenCasts) do
		if seenCasts[i] == label then return end
	end

	tinsert(seenCasts, 1, label)
	while getn(seenCasts) > 8 do
		tremove(seenCasts)
	end
end

function M:GetCCWatchStats()
	return castEvents, ownCasts, seenCasts
end

local function Store()
	local db = E.db.general
	if not db.ccWatch then
		db.ccWatch = {}
	end

	local cc = db.ccWatch
	if cc.enable == nil then cc.enable = true end
	if not tonumber(cc.maxRows) then cc.maxRows = 4 end
	--Spells added and removed by hand. A fixed list has now been wrong twice, and no list
	--written here can know which spells this realm added or which of them you care about.
	if not cc.extra then cc.extra = {} end
	if not cc.hidden then cc.hidden = {} end

	return cc
end

--The list as it actually stands: what ships here, plus yours, minus anything you have
--switched off.
function M:IsWatchedSpell(name)
	if not name then return false end

	local db = Store()
	if db.hidden[name] then return false end

	return (CC_SPELLS[name] or db.extra[name]) and true or false
end

function M:AddCCSpell(name)
	if not name or name == "" then return nil end

	local db = Store()
	db.hidden[name] = nil
	--Only recorded as an addition when it is not already built in, so the list of "yours"
	--stays a list of what you actually changed.
	if not CC_SPELLS[name] then db.extra[name] = true end

	return name
end

function M:RemoveCCSpell(name)
	if not name or name == "" then return nil end

	local db = Store()
	db.extra[name] = nil
	if CC_SPELLS[name] then db.hidden[name] = true end

	return name
end

local function LibDebuff()
	local NP = E:GetModule("NamePlates", true)
	return NP and NP.LibDebuff
end

--[[ the store ]]--
function M:AddCCWatch(guid, spellName, rank, spellID, texture)
	if not (guid and spellName) then return end

	local lib = LibDebuff()
	--Unhasted: casting speed shortens damage over time on this realm, not crowd control.
	local duration = lib and lib:GetDuration(spellName, rank, false) or 0
	--Returned rather than swallowed so /octoui-cc test can say WHICH of the two it was: no
	--LibDebuff at all, or a spell the duration table has no entry for.
	if duration <= 0 then
		return false, lib and "no duration in the table" or "LibDebuff not loaded"
	end

	local now = GetTime()
	local entry = watch[guid]

	if entry then
		--Re-cast on something already listed. The row keeps its place in the order rather
		--than jumping to the end, because the click that put it back under control was aimed
		--at where it currently is.
		entry.spell, entry.spellID, entry.texture = spellName, spellID, texture
		entry.start, entry.duration = now, duration
		entry.loose, entry.looseAt = nil, nil
	else
		watch[guid] = {
			guid = guid,
			spell = spellName,
			spellID = spellID,
			texture = texture,
			start = now,
			duration = duration,
			--Fixed at first sight and never touched again: it is what orders the list, and
			--rows that reorder themselves cannot be clicked without looking.
			added = now,
			lastSeen = now
		}
	end

	M:UpdateCCWatch()
	return true
end

function M:RemoveCCWatch(guid, why)
	if not watch[guid] then return end

	lastRemoved = format("%s -- %s", watch[guid].spell, why or "?")
	watch[guid] = nil
end

function M:GetCCWatch()
	return watch, lastRemoved
end

function M:GetCCSpells()
	return CC_SPELLS
end

function M:GetCCWatchSettings()
	return Store()
end

--[[
	Is our crowd control still on this mob?

	ONLY ANSWERABLE FOR THE UNIT YOU HAVE SELECTED. This client is sent aura data for your
	target and your group, and for nothing else -- a GUID gets you a name, a health value and
	a targeting call, but not a debuff list. SuperWoW does not change that, which is why
	Cursive-Raid carries a tooltip scanner and an armour-difference trick for Expose Armor
	rather than simply reading the debuff off the mob.

	The first version of this scanned regardless, and every mob went red the moment you
	looked away: no aura data reads identically to no debuff. Reported 2026-08-13 with the
	fear plainly still holding.

	So the scan runs only while the mob IS the target, and every other case trusts the
	timer. That makes an early break invisible until you look at the mob -- which is the
	honest position, since the client genuinely has not been told.

	What was on the mob when this concludes "broken" is recorded for /octoui-cc, because
	the other way to get here is our cast id and the debuff's id not matching, and the two
	need telling apart.
]]
--Returns whether the control is still on, AND whether that answer is worth anything. The
--second value is the whole point: "not there" and "cannot see" were one answer in the first
--version, and that is what turned every untargeted mob red.
local function ControlState(entry)
	if not entry.spellID then return true, false end

	local _, targetGUID = UnitExists("target")
	if targetGUID ~= entry.guid then return true, false end

	local seen, ids = 0, ""
	for i = 1, 16 do
		local texture, _, _, id = UnitDebuff(entry.guid, i)
		if not texture then break end

		if id == entry.spellID then return true, true end

		seen = seen + 1
		ids = (seen == 1) and tostring(id) or (ids..","..tostring(id))
	end

	entry.scanned = format("%d debuff(s) on it, ids %s, ours %s", seen,
		seen > 0 and ids or "none", tostring(entry.spellID))

	return false, true
end

--[[
	Losing control without looking at the mob.

	Targeting it is the only way to READ its debuffs, but it is not the only way to know it
	is loose. Two things a controlled mob cannot do:

	CAST. UNIT_CASTEVENT carries the caster's GUID, so a watched GUID appearing there is
	exact -- no name matching, no ambiguity, and it works for a mob never targeted.

	SWING. The combat log names the attacker at the start of the line. That is a name rather
	than a GUID, so it is only trusted when exactly one watched mob carries that name; two
	Infinite Whelps on the list and neither is blamed for what might be the other's swing.
	Getting this wrong is what produced the false LOOSE in the first place, so where it
	cannot be sure it says nothing.
]]
function M:NoteMobActed(guid, why)
	local entry = guid and watch[guid]
	if not entry or entry.loose then return end

	MarkLoose(entry, why)
	M:UpdateCCWatch()
end

local function NoteMobActedByName(msg)
	if not msg then return end

	local match, matches
	for _, entry in pairs(watch) do
		if not entry.loose then
			local name = UnitName(entry.guid)
			--Anchored, and followed by a space or an apostrophe, so "Infinite Whelp hits"
			--and "Infinite Whelp's Fireball" both count while "You hit Infinite Whelp"
			--does not.
			if name and (find(msg, "^"..name.." ") or find(msg, "^"..name.."'")) then
				matches = (matches or 0) + 1
				match = entry
			end
		end
	end

	if matches == 1 then
		MarkLoose(match, "acted")
		M:UpdateCCWatch()
	end
end

--[[ the display ]]--
local function RowOnClick()
	local guid = this.guid
	if not guid then return end

	--Right-click drops the row by hand. The only automatic removal is death, so this is the
	--way out for a mob that is genuinely finished with and the client never said so.
	if arg1 == "RightButton" then
		M:RemoveCCWatch(guid, "dismissed")
		M:UpdateCCWatch()
		return
	end

	--The whole reason for the list: one click puts the mob you feared back under the cursor
	--so it can be re-cast on, without hunting for it or tabbing through everything else.
	if type(TargetUnit) == "function" then TargetUnit(guid) end
end

local function CreateRow(index)
	local row = CreateFrame("Button", "OctoUI_CCWatchRow"..index, holder)
	E:Size(row, ROW_WIDTH, ROW_HEIGHT)
	E:SetTemplate(row, "Transparent")

	if index == 1 then
		E:Point(row, "TOPLEFT", holder, "TOPLEFT", 0, 0)
	else
		E:Point(row, "TOPLEFT", rows[index - 1], "BOTTOMLEFT", 0, -2)
	end

	local icon = CreateFrame("Frame", nil, row)
	E:Size(icon, ROW_HEIGHT - (E.Border * 2))
	E:Point(icon, "LEFT", row, "LEFT", E.Border, 0)
	E:CreateBackdrop(icon, "Default")
	row.iconFrame = icon

	row.icon = icon:CreateTexture(nil, "OVERLAY")
	row.icon:SetAllPoints()
	row.icon:SetTexCoord(unpack(E.TexCoords))

	local status = CreateFrame("StatusBar", nil, row)
	E:Point(status, "TOPLEFT", icon, "TOPRIGHT", E.Spacing * 2, 0)
	E:Point(status, "BOTTOMRIGHT", row, "BOTTOMRIGHT", -E.Border, 0)
	status:SetStatusBarTexture(E.media.normTex)
	E:RegisterStatusBar(status)
	status:SetMinMaxValues(0, 1)
	row.status = status

	local name = status:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(name, nil, nil, "OUTLINE")
	E:Point(name, "LEFT", status, "LEFT", 3, 0)
	name:SetJustifyH("LEFT")
	row.name = name

	local timer = status:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(timer, nil, nil, "OUTLINE")
	E:Point(timer, "RIGHT", status, "RIGHT", -3, 0)
	row.timer = timer

	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", RowOnClick)
	row:Hide()

	rows[index] = row
	return row
end

--Ordered by when each mob first joined the list and never re-ordered afterwards. Sorting by
--time remaining or by whether control has lapsed would move a row at the exact moment it
--becomes the one you are reaching for -- and since a row now stays until the mob dies, the
--position of everything above it is stable for as long as the fight lasts.
local function SortedEntries()
	local list = {}
	for _, entry in pairs(watch) do
		tinsert(list, entry)
	end

	sort(list, function(a, b) return (a.added or a.start) < (b.added or b.start) end)
	return list
end

function M:UpdateCCWatch()
	if not holder then return end

	local db = Store()
	local list = SortedEntries()
	local limit = tonumber(db.maxRows) or 4
	if limit > MAX_ROWS then limit = MAX_ROWS end

	local now = GetTime()
	local shown = 0

	--A list that is empty most of the time cannot be positioned: /moveui draws its mover, but
	--that is a small grey rectangle among twenty others and says nothing about what will
	--appear there or how big it will be. One sample row while config mode is up solves that,
	--and costs nothing the rest of the time.
	local preview = E.configMode and getn(list) == 0

	for index = 1, MAX_ROWS do
		local entry = list[index]
		local row = rows[index]

		if preview and index == 1 then
			row = row or CreateRow(1)

			row.guid = nil
			row.icon:SetTexture("Interface\\Icons\\Spell_Shadow_Possession")
			row.name:SetText(L["CC Watch"])
			row.timer:SetText("20")
			row.status:SetValue(1)
			row.status:SetStatusBarColor(0.2, 0.7, 0.2)

			row:Show()
			shown = shown + 1
		elseif entry and index <= limit and db.enable then
			row = row or CreateRow(index)

			local left = entry.start + entry.duration - now
			if left < 0 then left = 0 end

			row.guid = entry.guid
			row.icon:SetTexture(entry.texture)
			row.name:SetText(UnitName(entry.guid) or entry.spell)

			--Three states, and the bar is full for the one that matters most: a mob that is
			--loose should be the loudest thing on the list, not a bar that has shrunk to
			--nothing and reads as finished-with.
			if entry.loose then
				row.timer:SetText(L["CC_LOOSE"])
				row.status:SetValue(1)
				row.status:SetStatusBarColor(0.8, 0.15, 0.15)
			elseif left <= 3 then
				--Amber once re-casting is the next thing you should be doing: a cast, plus a
				--moment to react to it.
				row.timer:SetText(format("%.0f", left))
				row.status:SetValue(entry.duration > 0 and (left / entry.duration) or 0)
				row.status:SetStatusBarColor(0.9, 0.7, 0.1)
			else
				row.timer:SetText(format("%.0f", left))
				row.status:SetValue(entry.duration > 0 and (left / entry.duration) or 0)
				row.status:SetStatusBarColor(0.2, 0.7, 0.2)
			end

			row:Show()
			shown = shown + 1
		elseif row then
			row.guid = nil
			row:Hide()
		end
	end

	return shown
end

local function OnUpdate()
	if not this.lastUpdate then this.lastUpdate = 0 end

	this.lastUpdate = this.lastUpdate + arg1
	if this.lastUpdate < UPDATE_INTERVAL then return end
	this.lastUpdate = 0

	--Nothing controlled is the state this runs in almost all the time, so it costs one
	--table lookup and returns. The one pass after the last row goes is what clears them --
	--and the one after config mode opens is what draws the sample row, which is why the
	--comparison is against what SHOULD be on screen rather than against zero.
	if not next(watch) then
		local wanted = E.configMode and 1 or 0
		if shownRows ~= wanted then
			shownRows = M:UpdateCCWatch() or 0
		end
		return
	end

	local now = GetTime()
	local scan = (now - lastScan) >= SCAN_INTERVAL
	if scan then lastScan = now end

	for guid, entry in pairs(watch) do
		--Assigning nil to the key pairs() is on is the one mutation the iterator allows, so
		--removing the current entry here needs no second pass.
		local visible = UnitExists(guid)
		if visible then entry.lastSeen = now end

		--DEATH IS THE ONLY THING THAT TAKES A ROW AWAY, and only when the client says so
		--rather than merely failing to answer. Everything else changes how the row looks.
		if visible and UnitIsDead(guid) then
			M:RemoveCCWatch(guid, "died")
		elseif (now - (entry.lastSeen or now)) > UNSEEN_TIMEOUT then
			M:RemoveCCWatch(guid, "gone, not seen for five minutes")
		elseif entry.loose and not visible and (now - (entry.looseAt or now)) > LOOSE_TIMEOUT then
			M:RemoveCCWatch(guid, "loose and out of sight")
		elseif not entry.loose then
			if now >= entry.start + entry.duration then
				MarkLoose(entry, "ran out")
			elseif scan then
				local on, known = ControlState(entry)
				if known and not on then MarkLoose(entry, "broke early") end
			end
		elseif scan and entry.loose ~= "ran out" and now < entry.start + entry.duration then
			--A false alarm can be taken back, but only by looking straight at the mob: the
			--signals that set it are inferences and the debuff itself is not.
			local on, known = ControlState(entry)
			if known and on then
				entry.loose = nil
				entry.looseAt = nil
			end
		end
	end

	shownRows = M:UpdateCCWatch() or 0
end

--[[ events ]]--
local function OnEvent()
	--[[
		LEAVING COMBAT ENDS THE PULL, and with it every row that is no longer holding
		anything.

		Death was the only removal, and that is too narrow: a mob that resets and walks home
		never dies, so its row sat there red for five minutes. Reported 2026-08-13 with a
		Skeletal Acolyte that evaded.

		Rows still under control are kept -- a banish that is genuinely still up is worth
		seeing whether or not you are in combat, and something sapped before a pull would
		otherwise be swept away the moment it was cast.
	]]
	if event == "PLAYER_REGEN_ENABLED" then
		for guid, entry in pairs(watch) do
			if entry.loose then
				M:RemoveCCWatch(guid, "combat ended")
			end
		end

		M:UpdateCCWatch()
		return
	end

	if event ~= "UNIT_CASTEVENT" then
		--A combat log line. Only worth parsing while something is actually being watched,
		--which is almost never -- these events are the noisiest in the game.
		if next(watch) then NoteMobActedByName(arg1) end
		return
	end

	--Counted before any test at all, so a zero here says the event itself never arrives --
	--which is the one failure no amount of looking at this module would explain.
	castEvents = castEvents + 1

	--A controlled mob cannot cast. Checked before anything else, because this fires for the
	--mob whether or not it is our own cast being reported.
	if arg1 then M:NoteMobActed(arg1, "started casting") end

	if not Store().enable then return end
	if type(SpellInfo) ~= "function" then return end

	--arg1 caster GUID, arg2 target GUID, arg3 START/CAST/CHANNEL/FAIL, arg4 spell id
	if arg3 ~= "CAST" or not arg2 then return end

	local _, playerGUID = UnitExists("player")
	local _, petGUID = UnitExists("pet")
	if not (arg1 == playerGUID or (petGUID and arg1 == petGUID)) then return end

	ownCasts = ownCasts + 1

	local name, rank, texture = SpellInfo(arg4)
	local matched = M:IsWatchedSpell(name)
	NoteCast(name, matched)

	if not matched then return end

	M:AddCCWatch(arg2, name, rank, arg4, texture)
end

--[[ options ]]--
local function BuildOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	if not general or not general.args then return end

	general.args.ccWatch = {
		--Between Mount Gear (5.5) and Chat Bubbles (6).
		order = 5.7,
		type = "group",
		name = L["CC Watch"],
		args = {
			intro = {
				order = 1,
				type = "description",
				name = L["Lists what you have crowd controlled, with the time left on each. Click a row to target that mob. Only your own casts appear, so another player's fear on the same mob is not counted as yours."]
			},
			enable = {
				order = 2,
				type = "toggle",
				name = L["Enable"],
				get = function() return Store().enable and true or false end,
				set = function(_, value)
					Store().enable = value and true or false
					M:UpdateCCWatch()
				end
			},
			maxRows = {
				order = 3,
				type = "range",
				name = L["Rows"],
				desc = L["How many at once. Anything past this is still tracked, it just does not have a row."],
				min = 1, max = MAX_ROWS, step = 1,
				get = function() return tonumber(Store().maxRows) or 4 end,
				set = function(_, value)
					Store().maxRows = value
					M:UpdateCCWatch()
				end
			},
			addSpell = {
				order = 4,
				type = "input",
				width = "full",
				name = L["Watch another spell"],
				desc = L["The spell's name exactly as the game writes it. It also needs an entry in the debuff duration table, or there is no timer to show."],
				get = function() return "" end,
				set = function(_, value) M:AddCCSpell(value) end
			},
			dropSpell = {
				order = 5,
				type = "input",
				width = "full",
				name = L["Stop watching a spell"],
				desc = L["Removes it from the list, whether it was one of yours or one of the built-in ones."],
				get = function() return "" end,
				set = function(_, value) M:RemoveCCSpell(value) end
			},
			move = {
				order = 6,
				type = "description",
				name = L["Use /moveui to position the list. /octoui-cc lists every spell currently watched."]
			}
		}
	}
end

function M:LoadCCWatch()
	Store()

	--Anchored by its TOP because the rows hang downward from it: anchor the other edge and
	--the list grows in both directions as it fills. See the note in Modules\Misc\LootRoll.lua.
	holder = CreateFrame("Frame", "OctoUI_CCWatchHolder", E.UIParent)
	E:Size(holder, ROW_WIDTH, ROW_HEIGHT)
	E:Point(holder, "TOP", E.UIParent, "TOP", 0, -220)

	watcher = CreateFrame("Frame", nil, holder)
	watcher:SetScript("OnUpdate", OnUpdate)

	--Its own frame rather than M:RegisterEvent: Misc already owns events on the module, and
	--AceEvent keeps one callback per event per object.
	local events = CreateFrame("Frame")
	events:RegisterEvent("UNIT_CASTEVENT")
	--The end of the pull, which is what clears a mob that reset instead of dying.
	events:RegisterEvent("PLAYER_REGEN_ENABLED")

	--A mob swinging at something is loose, and the combat log is the only place that shows
	--up for a mob you are not targeting. See NoteMobActedByName.
	events:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
	events:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
	events:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS")
	events:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES")
	events:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS")
	events:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES")
	events:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
	events:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE")

	events:SetScript("OnEvent", OnEvent)

	BuildOptions()

	--After the SetPoint above and after E.db is loaded, because CreateMover reads the
	--frame's current point as the mover's default.
	E:CreateMover(holder, "CCWatchMover", L["CC Watch"])
end
