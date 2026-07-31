local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, tonumber, type = pairs, tonumber, type
local format, sort = string.format, table.sort
local tinsert, getn = table.insert, table.getn
--WoW API / Variables
local GetTime = GetTime
local UnitName = UnitName
local UnitExists = UnitExists
local CreateFrame = CreateFrame
local IsShiftKeyDown = IsShiftKeyDown
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

	The cost is a hard dependency on nampower, which is why Available() exists and why
	nothing here assumes the events registered. From 4.5.0 onwards registering the
	event is enough to turn it on -- the NP_Enable*Events CVars are deprecated
	compatibility toggles and do not need setting.

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
local debugging

local function Available()
	return available and true or false
end

--SuperWoW returns the GUID as a second value from UnitExists
local function GuidOf(unit)
	local exists, guid = UnitExists(unit)
	if exists and guid then return guid end
end

local function RefreshTracked()
	tracked, owners = {}, {}

	local function add(unit, ownerUnit)
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

	for i = 1, 4 do
		add("party"..i)
		add("partypet"..i, "party"..i)
	end

	for i = 1, 40 do
		add("raid"..i)
		add("raidpet"..i, "raid"..i)
	end
end

--A GUID is a usable unit token under SuperWoW, so the name usually comes straight
--back. Pets and anything out of range may not resolve, in which case the GUID stands
--in for a name rather than the entry being dropped -- a nameless row is still a real
--source, and it will usually resolve on a later look.
local function ResolveName(guid)
	if not guid then return end

	local name = UnitName(guid)
	if name and name ~= "" and name ~= "Unknown Entity" then return name end

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

local function Record(guid, spell, amount, isHeal)
	amount = tonumber(amount)
	if not (guid and amount and amount > 0) then return end

	--Anything outside the group is somebody else's fight
	if not tracked[guid] then return end

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

local function OnEvent()
	if event == "PLAYER_REGEN_DISABLED" then
		--A new fight wipes the current segment but never the overall one
		current = {}
		combatStart, combatEnd = GetTime(), nil
		return
	elseif event == "PLAYER_REGEN_ENABLED" then
		combatEnd = GetTime()

		--Banked so the overall figure is time spent fighting, not wall clock since
		--login and not the gap between first and last hit
		if combatStart then
			combatTime = combatTime + (combatEnd - combatStart)
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
		Record(arg2, arg3, arg4)
	elseif event == "SPELL_HEAL_BY_SELF" or event == "SPELL_HEAL_BY_OTHER" then
		Record(arg2, arg3, arg4, true)

	--Swings and damage shields name the source first
	elseif event == "AUTO_ATTACK_SELF" or event == "AUTO_ATTACK_OTHER" then
		Record(arg1, "melee", arg3)
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

		Record(source, "shield", arg3)
	end
end

--Seconds the segment has been running. Falls back to the spread of the entries
--themselves when combat never formally started, which is how a dummy parse looks.
function M:MeterDuration(segment)
	if segment == "current" then
		if not combatStart then return 0 end
		return (combatEnd or GetTime()) - combatStart
	end

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
	local store = (segment == "current") and current or overall
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
	current, overall = {}, {}
	combatStart, combatEnd, combatTime = nil, nil, 0
end

function M:InitializeDamageMeter()
	watcher = CreateFrame("Frame", "OctoUI_DamageMeter", E.UIParent)
	watcher:SetScript("OnEvent", OnEvent)

	--Registering an event this client has never heard of raises, and without nampower
	--none of these exist. One pcall decides whether the meter can run at all, rather
	--than eight separate failures.
	local groups = {DAMAGE_EVENTS, SWING_EVENTS, SHIELD_EVENTS, HEAL_EVENTS}
	for i = 1, getn(groups) do
		local group = groups[i]
		for j = 1, getn(group) do
			local ok = pcall(watcher.RegisterEvent, watcher, group[j])
			if not ok then
				available = nil
				watcher:UnregisterAllEvents()
				return
			end

			available = true
		end
	end

	--Best effort; the meter works without them, only shield attribution needs them
	for i = 1, getn(AURA_EVENTS) do
		pcall(watcher.RegisterEvent, watcher, AURA_EVENTS[i])
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

local MODES = {damage = "damage", healing = "healing"}

local function MeterDB()
	return E.db.general.damageMeter or P.general.damageMeter
end

local function Short(value)
	if value >= 1000000 then return format("%.1fm", value / 1000000) end
	if value >= 1000 then return format("%.1fk", value / 1000) end

	return format("%d", value)
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

	row:Hide()

	return row
end

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

function M:UpdateMeterWindow()
	if not window or not window:IsShown() then return end

	local db = MeterDB()
	local segment = db.segment or "current"
	local mode = db.mode or MODES.damage
	local data, duration = M:MeterData(segment)

	window.title:SetText(format("%s  |cff999999%s %.0fs|r",
		(mode == MODES.healing) and L["Healing"] or L["Damage"], segment, duration))

	--Everything is scaled against the top row, which is what makes a bar chart
	--readable at a glance; an absolute scale would leave every bar stubby on trash
	local top = 0
	for i = 1, getn(data) do
		local value = (mode == MODES.healing) and data[i].healing or data[i].damage
		if value > top then top = value end
	end

	local shown = 0
	for i = 1, db.bars do
		local row = rows[i]
		local entry = data[i]
		local value = entry and ((mode == MODES.healing) and entry.healing or entry.damage) or 0

		if entry and value > 0 then
			shown = shown + 1
			row:SetValue((top > 0) and (value / top) or 0)

			local color = E.media.rgbvaluecolor
			row:SetStatusBarColor(color[1], color[2], color[3])

			row.label:SetText(format("%d. %s", i, entry.name))
			row.amount:SetText(format("%s  |cff999999%.0f|r", Short(value),
				(mode == MODES.healing) and entry.hps or entry.dps))
			row:Show()
		else
			row:Hide()
		end
	end

	--Collapse to the rows actually in use rather than leaving dead space. The frame is
	--anchored by its bottom edge, so this grows the top upwards and the window never
	--reaches further down the screen than where it was placed.
	E:Height(window, 22 + (shown * (db.height + 1)) + 2)
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
	E:Point(window, "BOTTOMLEFT", E.UIParent, "BOTTOMLEFT", 428, 30)
	window:SetFrameStrata("LOW")

	window.title = window:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(window.title, nil, 11, "OUTLINE")
	E:Point(window.title, "TOPLEFT", window, "TOPLEFT", 4, -5)
	window.title:SetJustifyH("LEFT")

	--Segment and mode toggles, and a reset that puts the window back on its anchor
	window.reset = TitleButton("R", 16, "TOPRIGHT", window, "TOPRIGHT", -3)
	window.reset:SetScript("OnClick", function()
		M:ResetMeterPosition()
	end)

	window.mode = TitleButton(L["Damage"], 46, "TOPRIGHT", window.reset, "TOPLEFT", -2)
	window.mode:SetScript("OnClick", function()
		local cfg = MeterDB()
		cfg.mode = (cfg.mode == MODES.healing) and MODES.damage or MODES.healing
		this.text:SetText((cfg.mode == MODES.healing) and L["Healing"] or L["Damage"])
		M:UpdateMeterWindow()
	end)

	window.segment = TitleButton(L["Current"], 50, "TOPRIGHT", window.mode, "TOPLEFT", -2)
	window.segment:SetScript("OnClick", function()
		local cfg = MeterDB()
		cfg.segment = (cfg.segment == "overall") and "current" or "overall"
		this.text:SetText((cfg.segment == "overall") and L["Overall"] or L["Current"])
		M:UpdateMeterWindow()
	end)

	window.mode.text:SetText((db.mode == MODES.healing) and L["Healing"] or L["Damage"])
	window.segment.text:SetText((db.segment == "overall") and L["Overall"] or L["Current"])

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
	--/moveui write the same E.db.movers entry instead of two positions fighting
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", function()
		if not IsShiftKeyDown() then return end

		local mover = _G["DamageMeterMover"]
		if mover then mover:StartMoving() end
	end)
	window:SetScript("OnDragStop", function()
		local mover = _G["DamageMeterMover"]
		if not mover then return end

		mover:StopMovingOrSizing()

		local x, y, point = E:CalculateMoverPoints(mover)
		mover:ClearAllPoints()
		E:Point(mover, point, E.UIParent, point, x, y)
		E:SaveMoverPosition("DamageMeterMover")
	end)

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
