local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, ipairs, type, tonumber, next = pairs, ipairs, type, tonumber, next
local getn, tinsert, sort = table.getn, table.insert, table.sort
local format, lower = string.format, string.lower
--WoW API / Variables
local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitName = UnitName
local UnitExists = UnitExists
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
	UnitDebuff's fourth value -- and the row goes the moment it is no longer there. That
	check is skipped while the client cannot see the mob, because "no data" and "no debuff"
	look identical and dropping the row on the first is exactly wrong: a feared mob running
	out of range is when you most want to know how long is left.
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
	["Gouge"] = true
}

local ROW_WIDTH, ROW_HEIGHT = 190, 20
local MAX_ROWS = 6
local UPDATE_INTERVAL = 0.05
--The break check walks a mob's debuffs, so it runs a fifth as often as the bars redraw.
local SCAN_INTERVAL = 0.25

local watch = {}
local rows = {}
local holder, watcher
local lastScan = 0
local lastRemoved
--How many rows are on screen, so the idle path can tell "already cleared" from "needs
--clearing" without touching the rows every frame.
local shownRows = 0

local function Store()
	local db = E.db.general
	if not db.ccWatch then
		db.ccWatch = {}
	end

	local cc = db.ccWatch
	if cc.enable == nil then cc.enable = true end
	if not tonumber(cc.maxRows) then cc.maxRows = 4 end

	return cc
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
	if duration <= 0 then return end

	watch[guid] = {
		guid = guid,
		spell = spellName,
		spellID = spellID,
		texture = texture,
		start = GetTime(),
		duration = duration
	}

	M:UpdateCCWatch()
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

--Is our crowd control still on this mob?
--
--Answered by spell id against the mob's own debuffs, which needs neither a target nor a
--tooltip scan. Two honest "do not know" cases return true rather than dropping the row: a
--client that cannot see the mob has no debuffs to report, and a client without SuperWoW
--gives no ids to compare.
local function StillControlled(entry)
	if not entry.spellID then return true end
	if not UnitExists(entry.guid) then return true end

	for i = 1, 16 do
		local texture, _, _, id = UnitDebuff(entry.guid, i)
		if not texture then break end
		if id == entry.spellID then return true end
	end

	return false
end

--[[ the display ]]--
local function RowOnClick()
	local guid = this.guid
	if not guid then return end

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

	row:SetScript("OnClick", RowOnClick)
	row:Hide()

	rows[index] = row
	return row
end

--Newest first: the thing you just feared is the thing you are about to have to think about,
--and a list that reorders itself as timers pass is a list you cannot click by muscle memory.
local function SortedEntries()
	local list = {}
	for _, entry in pairs(watch) do
		tinsert(list, entry)
	end

	sort(list, function(a, b) return a.start > b.start end)
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

	for index = 1, MAX_ROWS do
		local entry = list[index]
		local row = rows[index]

		if entry and index <= limit and db.enable then
			row = row or CreateRow(index)

			local left = entry.start + entry.duration - now
			if left < 0 then left = 0 end

			row.guid = entry.guid
			row.icon:SetTexture(entry.texture)
			row.name:SetText(UnitName(entry.guid) or entry.spell)
			row.timer:SetText(format("%.0f", left))
			row.status:SetValue(entry.duration > 0 and (left / entry.duration) or 0)

			--Green while it is comfortably yours, amber once re-casting is the next thing
			--you should be doing. The threshold is a cast plus a moment to react.
			if left <= 3 then
				row.status:SetStatusBarColor(0.9, 0.7, 0.1)
			else
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
	--table lookup and returns. The one pass after the last row goes is what clears them.
	if not next(watch) then
		if shownRows > 0 then
			shownRows = M:UpdateCCWatch() or 0
		end
		return
	end

	local now = GetTime()
	local scan = (now - lastScan) >= SCAN_INTERVAL
	if scan then lastScan = now end

	for guid, entry in pairs(watch) do
		--Assigning nil to the key pairs() is on is the one mutation the iterator allows.
		if now >= entry.start + entry.duration then
			M:RemoveCCWatch(guid, "ran out")
		elseif scan and not StillControlled(entry) then
			M:RemoveCCWatch(guid, "broke early")
		end
	end

	shownRows = M:UpdateCCWatch() or 0
end

--[[ events ]]--
local function OnEvent()
	if event ~= "UNIT_CASTEVENT" then
		--PLAYER_REGEN_DISABLED and friends only clear the slate between pulls.
		return
	end

	if not Store().enable then return end
	if type(SpellInfo) ~= "function" then return end

	--arg1 caster GUID, arg2 target GUID, arg3 START/CAST/CHANNEL/FAIL, arg4 spell id
	if arg3 ~= "CAST" or not arg2 then return end

	local _, playerGUID = UnitExists("player")
	local _, petGUID = UnitExists("pet")
	if not (arg1 == playerGUID or (petGUID and arg1 == petGUID)) then return end

	local name, rank, texture = SpellInfo(arg4)
	if not (name and CC_SPELLS[name]) then return end

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
			move = {
				order = 4,
				type = "description",
				name = L["Use /moveui to position the list."]
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
	events:SetScript("OnEvent", OnEvent)

	BuildOptions()

	--After the SetPoint above and after E.db is loaded, because CreateMover reads the
	--frame's current point as the mover's default.
	E:CreateMover(holder, "CCWatchMover", L["CC Watch"])
end
