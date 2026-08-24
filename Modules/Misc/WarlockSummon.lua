local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");
local LSM = LibStub("LibSharedMedia-3.0");

--Cache global variables
--Lua functions
local ipairs = ipairs
local getn, tinsert, tremove, sort = table.getn, table.insert, table.remove, table.sort
local format, find, lower, gsub = string.format, string.find, string.lower, string.gsub
--WoW API / Variables
local CreateFrame = CreateFrame
local GetTime = GetTime
local GetNumRaidMembers = GetNumRaidMembers
local GetRaidRosterInfo = GetRaidRosterInfo
local GetContainerNumSlots = GetContainerNumSlots
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetZoneText, GetSubZoneText = GetZoneText, GetSubZoneText
local UnitName = UnitName
local UnitExists = UnitExists
local UnitDebuff = UnitDebuff
local UnitAffectingCombat = UnitAffectingCombat
local CheckInteractDistance = CheckInteractDistance
local TargetUnit = TargetUnit
local CastSpellByName = CastSpellByName
local SendChatMessage = SendChatMessage
local SendAddonMessage = SendAddonMessage
local PlaySoundFile = PlaySoundFile
local IsControlKeyDown = IsControlKeyDown
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

--[[
	The summon list. A raider types the trigger word in chat, every warlock in the raid
	gets a clickable row, and one click targets them, casts Ritual of Summoning and takes
	the row off everybody's list.

	Adapted from LockPort by Gurky-Turtle, which this replaces. That addon carries no
	licence and its repository is gone, which puts it where ShaguDPS is -- see the note at
	the top of Modules\Misc\DamageMeter.lua. So this is written against OctoUI's own
	toolkit rather than vendored: the workflow is not copyrightable, the client functions
	it calls are facts about the client, and none of the original file is here.

	THE WIRE PROTOCOL IS KEPT DELIBERATELY. RSAdd and RSRemove carrying a bare player name
	are what LockPort sent, so a raid that is half OctoUI and half the old addon still
	shares one list. Changing the prefixes would be tidier and would silently split the
	raid in two, which is the one failure this tool cannot afford.

	NOTHING LOADS ON ANY OTHER CLASS. No frame, no chat events, no options page -- the whole
	module returns at the top of LoadWarlockSummon. Upstream relayed the trigger from every
	class on the theory that a /say carries 25 yards and a whisper reaches one person, so a
	bystander could pass it on. It is not worth it: the person asking sees their own chat
	line, so their client relays it already, and the case that needs a third party is one
	where the asker has no addon and some non-warlock happens to be in earshot.

	WARLOCKS STILL RELAY TO EACH OTHER, which is the half that pays for itself -- a /say
	heard by the warlock at the stone reaches the two who are out of range.

	Relays are rate limited per name. Upstream rebroadcast on every match from every client,
	so one trigger word in raid chat produced one addon message per raider running it.

	THE ROSTER IS LOOKED UP FRESH EVERY TIME and nothing is cached across clicks. The
	original kept the resolved unit in a global it never cleared, so clicking a name who had
	left the raid summoned whoever had been resolved last -- a real cost, in a tool whose
	whole job is spending somebody's soul shard on the right person.
]]

--The addon channel LockPort used. See the note above before touching these.
local PREFIX_ADD = "RSAdd"
local PREFIX_REMOVE = "RSRemove"

--Matched against UnitDebuff's texture. On this client UnitDebuff returns a texture path and
--nothing else -- there is no name to compare -- so the icon is the identifier. Evil Twin
--blocks the summon outright, and finding that out by burning a shard is the bad way.
local EVIL_TWIN_TEXTURE = "spell_shadow_charm"

--A sound OctoUI SHIPS, so it cannot be missing. The original played
--Sound\Creature\Necromancer\NecromancerReady1.wav, which is not present on this client --
--and PlaySoundFile fails silently on a path that does not resolve, so the alert was simply
--never heard and nothing anywhere said why.
--
--A CHIME RATHER THAN A VOICE CLIP, deliberately. Most of the sounds OctoUI registers are
--spoken lines; "Warning" was the first default here and turned out to be a voice saying the
--word, which is both slow and tiring when it fires a dozen times before a pull. This one is
--short and wordless. Anything else can be picked in the options, and the dropdown plays each
--sound as you move through it, which is the only way to hear what a file does on this client.
local DEFAULT_SOUND = "ElvUI Aska"

local SOUL_SHARD_ID = 6265
local MAX_ROWS = 10
local ROW_WIDTH, ROW_HEIGHT = 120, 16
local RELAY_INTERVAL = 5

local holder = nil
local rows = {}
local requests = {}

--Held open by hand, with /octoui-summon show. Session only and never saved: it is a look at
--the thing, not a preference. Without it the toggle fought the update -- show called Show(),
--the next update saw an empty list and called Hide(), and the command read as doing nothing.
local forceShown = false
local lastRelay = {}

local function Store()
	local db = E.db.general
	if not db.warlockSummon then
		db.warlockSummon = {}
	end

	local ws = db.warlockSummon
	if ws.enable == nil then ws.enable = true end
	if ws.whisper == nil then ws.whisper = true end
	if ws.zone == nil then ws.zone = true end
	if ws.shards == nil then ws.shards = true end
	if ws.sound == nil then ws.sound = true end
	if not ws.soundFile then ws.soundFile = DEFAULT_SOUND end
	if not ws.announce then ws.announce = "SAY" end
	if not ws.trigger or ws.trigger == "" then ws.trigger = "123" end

	return ws
end

local function IndexOf(name)
	for index, entry in ipairs(requests) do
		if entry == name then return index end
	end
end

--A unit token for a name currently in the raid, or nil. Rebuilt per call on purpose: a
--cached roster outlives the raid it described, and every wrong answer here costs a shard.
local function UnitForName(name)
	local count = GetNumRaidMembers()
	for index = 1, count do
		if GetRaidRosterInfo(index) == name then
			return "raid"..index
		end
	end
end

local function ClassOfName(name)
	local count = GetNumRaidMembers()
	for index = 1, count do
		--The sixth return is the uppercase English token; the fifth is localised.
		local rosterName, _, _, _, _, fileName = GetRaidRosterInfo(index)
		if rosterName == name then
			return fileName
		end
	end
end

--By item id, not by name: Soul Shard is only the name on an English client, and the
--original's name match therefore counted zero shards everywhere else.
local function CountSoulShards()
	local total = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot)
			if link and find(link, "item:"..SOUL_SHARD_ID..":") then
				local _, count = GetContainerItemInfo(bag, slot)
				total = total + (count or 1)
			end
		end
	end

	return total
end

local function HasEvilTwin(unit)
	for i = 1, 16 do
		local texture = UnitDebuff(unit, i)
		if not texture then break end
		if find(lower(texture), EVIL_TWIN_TEXTURE) then return true end
	end

	return false
end

--A LibSharedMedia name, or a raw file path. The dropdown can only offer what LSM knows, and
--everything OctoUI registers is one of its own .ogg files -- so without the second form
--there is no way to reach the thousands of sounds the CLIENT ships, and no way to find out
--which of those paths are even real on this server. There is no list to consult for that;
--the only test is playing one.
local function ResolveSound(value)
	if not value or value == "" then return nil end

	local path = LSM and LSM:Fetch("sound", value, true)
	if path then return path end

	--Not a registered name. Treat it as a path only if it looks like one, so a typo in a
	--sound name is reported rather than handed to PlaySoundFile to swallow. Spelled out
	--rather than compressed into one character class, which is how .mp3 got missed once.
	local lowered = lower(value)
	if find(value, "\\") or find(value, "/")
		or find(lowered, "%.wav$") or find(lowered, "%.ogg$") or find(lowered, "%.mp3$") then
		return value
	end
end

--Returns the path it played, or nil, so /octoui-summon can tell "switched off" and "that
--name resolves to nothing" apart from "it played and you heard nothing".
function M:PlayWarlockSummonAlert(override)
	local db = Store()

	--Falls back rather than passing nil to PlaySoundFile, which is silent either way. A
	--saved name can stop resolving: the media it points at belongs to whichever addons are
	--loaded, not to this profile.
	local path = ResolveSound(override or db.soundFile) or ResolveSound(DEFAULT_SOUND)
	if not path then return end

	PlaySoundFile(path)
	return path
end

--Set from chat, which is the only way to keep a raw client path -- the options dropdown
--cannot offer one. Returns the resolved path, or nil if it resolves to nothing, in which
--case nothing is saved: a setting that silently plays no sound is the bug being fixed here.
function M:SetWarlockSummonAlert(value)
	local path = ResolveSound(value)
	if not path then return nil end

	Store().soundFile = value
	PlaySoundFile(path)
	return path
end

local function Broadcast(prefix, name)
	if GetNumRaidMembers() > 0 then
		SendAddonMessage(prefix, name, "RAID")
	end
end

function M:AddSummonRequest(name)
	if not name or name == "" then return false end
	if name == UnitName("player") then return false end
	if IndexOf(name) then return false end

	tinsert(requests, name)
	M:UpdateWarlockSummonList()

	if Store().sound then
		M:PlayWarlockSummonAlert()
	end

	return true
end

function M:RemoveSummonRequest(name, broadcast)
	local index = IndexOf(name)
	if not index then return false end

	tremove(requests, index)
	if broadcast then
		Broadcast(PREFIX_REMOVE, name)
	end

	M:UpdateWarlockSummonList()
	return true
end

function M:GetSummonRequests()
	return requests
end

--For /octoui-summon. The file loading and LoadWarlockSummon actually running are two
--different things -- Misc:Initialize stashes its failures rather than raising them -- and
--without this the report cannot tell them apart, because every other thing it prints
--answers the same either way.
function M:GetWarlockSummonFrame()
	return holder
end

--Warlocks first: summoning another warlock is what turns one summoner into two, so it is
--the click that pays for itself. Order is otherwise the order the requests arrived in.
local function SortedRequests()
	local list = {}
	local order = {}

	for index, name in ipairs(requests) do
		tinsert(list, { name = name, class = ClassOfName(name) })
		order[name] = index
	end

	sort(list, function(a, b)
		local aLock = a.class == "WARLOCK"
		local bLock = b.class == "WARLOCK"
		if aLock ~= bLock then return aLock end
		return order[a.name] < order[b.name]
	end)

	return list
end

--Takes no argument: on this client the clicked button arrives as the global arg1, and
--`this` is the row it landed on. Nothing is captured from the loop that built the rows.
local function RowOnClick()
	local name = this.summonName
	if not name then return end

	if arg1 == "RightButton" then
		M:RemoveSummonRequest(name, true)
		return
	end

	local unit = UnitForName(name)
	if not unit then
		E:Print(format(L["WARLOCKSUMMON_NOT_IN_RAID"], name))
		Broadcast(PREFIX_REMOVE, name)
		M:RemoveSummonRequest(name, false)
		return
	end

	--Ctrl-click targets without summoning: a look before spending a shard.
	if IsControlKeyDown() then
		TargetUnit(unit)
		return
	end

	M:SummonPlayer(name, unit)
end

local function CreateRow(index)
	local row = CreateFrame("Button", "OctoUI_WarlockSummonRow"..index, holder)
	E:Size(row, ROW_WIDTH, ROW_HEIGHT)
	E:SetTemplate(row, "Transparent")

	if index == 1 then
		E:Point(row, "TOPLEFT", holder, "TOPLEFT", 0, 0)
	else
		E:Point(row, "TOPLEFT", rows[index - 1], "BOTTOMLEFT", 0, -2)
	end

	local text = row:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(text, nil, nil, "OUTLINE")
	E:Point(text, "LEFT", row, "LEFT", 4, 0)
	E:Point(text, "RIGHT", row, "RIGHT", -4, 0)
	text:SetJustifyH("LEFT")
	row.text = text

	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", RowOnClick)
	row:Hide()

	rows[index] = row
	return row
end

function M:UpdateWarlockSummonList()
	if not holder then return end

	--Asked for explicitly -- /octoui-summon show, or config mode -- rather than appearing
	--because somebody wants a port. That is the difference between the two ways this frame
	--becomes visible, and it decides whether an empty list still draws a row.
	local deliberate = forceShown or E.configMode

	local db = Store()
	local list = SortedRequests()

	--The holder draws nothing on its own -- every visible pixel belongs to a row -- so an
	--empty list has to keep one row alive or "show" displays a frame you cannot see. Same
	--reason CC Watch does it: its mover is otherwise one grey rectangle among twenty.
	local preview = deliberate and getn(list) == 0
	local shown = 0

	for index = 1, MAX_ROWS do
		local entry = list[index]
		local row = rows[index]

		if preview and index == 1 then
			row = row or CreateRow(1)
			row.summonName = nil
			--Greyed and labelled as empty, so it reads as the list with nobody on it rather
			--than as a name you could click.
			row.text:SetText(L["WARLOCKSUMMON_EMPTY_ROW"])
			row.text:SetTextColor(0.6, 0.6, 0.6)
			row:Show()
			shown = shown + 1
		elseif entry and db.enable then
			row = row or CreateRow(index)
			row.summonName = entry.name
			row.text:SetText(entry.name)

			local color = entry.class and RAID_CLASS_COLORS[entry.class]
			if color then
				row.text:SetTextColor(color.r, color.g, color.b)
			else
				row.text:SetTextColor(1, 1, 1)
			end

			row:Show()
			shown = shown + 1
		elseif row then
			row.summonName = nil
			row:Hide()
		end
	end

	E:Height(holder, (shown > 0 and (shown * (ROW_HEIGHT + 2))) or ROW_HEIGHT)

	--The window follows the list. Nothing to summon is the normal state, and a permanent
	--empty box in the middle of the screen is why people switch a tool like this off -- so
	--the only thing that keeps an empty one up is having asked for it, which `preview` above
	--has already turned into a row.
	if shown > 0 then
		holder:Show()
	else
		holder:Hide()
	end

	return shown
end

function M:SummonPlayer(name, unit)
	unit = unit or UnitForName(name)
	if not unit then
		E:Print(format(L["WARLOCKSUMMON_NOT_IN_RAID"], name))
		return
	end

	if UnitAffectingCombat("player") or UnitAffectingCombat(unit) then
		E:Print(format(L["WARLOCKSUMMON_IN_COMBAT"], name))
		return
	end

	local db = Store()

	--Target FIRST, then read the debuffs. The original scanned "target" before it
	--retargeted, so the Evil Twin check answered for whoever you happened to have selected.
	--It was answering a different question every time.
	TargetUnit(unit)

	if HasEvilTwin("target") then
		SendChatMessage(L["WARLOCKSUMMON_EVILTWIN_WHISPER"], "WHISPER", nil, name)
		E:Print(format(L["WARLOCKSUMMON_EVILTWIN"], name))
		M:RemoveSummonRequest(name, true)
		return
	end

	--Already standing next to you. 4 is the follow check, which is 28 yards on this client.
	if UnitExists("target") and CheckInteractDistance("target", 4) then
		E:Print(format(L["WARLOCKSUMMON_IN_RANGE"], name))
		M:RemoveSummonRequest(name, true)
		return
	end

	CastSpellByName("Ritual of Summoning")

	local zone = ""
	if db.zone then
		zone = " "..format(L["WARLOCKSUMMON_TO_ZONE"], GetZoneText())
		local subZone = GetSubZoneText()
		if subZone and subZone ~= "" then
			zone = zone.." - "..subZone
		end
	end

	if db.announce ~= "NONE" then
		local public = format(L["WARLOCKSUMMON_SAY"], name)..zone

		--Reported as what will be left once this cast lands, which is the number the raid
		--is actually asking about. Guarded because the original subtracted one from a count
		--that was nil when you had none, and threw instead of summoning.
		if db.shards then
			local left = CountSoulShards() - 1
			if left < 0 then left = 0 end
			public = public.." "..format(L["WARLOCKSUMMON_SHARDS"], left)
		end

		SendChatMessage(public, db.announce)
	end

	if db.whisper then
		SendChatMessage(L["WARLOCKSUMMON_WHISPER"]..zone, "WHISPER", nil, name)
	end

	M:RemoveSummonRequest(name, true)
end

--Returns whether it is now being held open, so the command can say which way it went rather
--than leaving you to work it out from an empty screen.
function M:ToggleWarlockSummon()
	if not holder then return nil end

	forceShown = not forceShown

	--Never Show() the holder directly: it draws nothing by itself, and the update is what
	--puts a row in it. Doing both is what made this look broken.
	M:UpdateWarlockSummonList()

	return forceShown
end

--Names that have left the raid are dropped. Upstream kept them forever, so a list left open
--across a raid reshuffle filled up with people nobody could summon.
local function PruneRequests()
	if getn(requests) == 0 then return end

	if GetNumRaidMembers() == 0 then
		for index = getn(requests), 1, -1 do
			tremove(requests, index)
		end
		M:UpdateWarlockSummonList()
		return
	end

	local changed = false
	for index = getn(requests), 1, -1 do
		if not UnitForName(requests[index]) then
			tremove(requests, index)
			changed = true
		end
	end

	if changed then
		M:UpdateWarlockSummonList()
	end
end

local function OnEvent()
	local db = Store()
	if not db.enable then return end

	if event == "CHAT_MSG_ADDON" then
		if arg1 == PREFIX_ADD then
			M:AddSummonRequest(arg2)
		elseif arg1 == PREFIX_REMOVE then
			M:RemoveSummonRequest(arg2, false)
		end

		return
	end

	if event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
		PruneRequests()
		return
	end

	--A chat line from anyone, on any of the channels a summon request realistically
	--arrives on. arg1 is the message, arg2 the sender.
	local trigger = db.trigger
	if not trigger or trigger == "" then return end
	if not arg1 or not arg2 then return end

	--Anchored at the start, and the trigger is escaped so a word carrying a %, - or . is
	--matched literally rather than read as a pattern.
	local pattern = "^"..gsub(trigger, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	if not find(arg1, pattern) then return end

	local now = GetTime()
	if lastRelay[arg2] and (now - lastRelay[arg2]) < RELAY_INTERVAL then return end
	lastRelay[arg2] = now

	--Relayed to the other warlocks, who may be out of earshot of a /say, and added here
	--directly -- our own relay does not come back to us.
	Broadcast(PREFIX_ADD, arg2)
	M:AddSummonRequest(arg2)
end

local function BuildOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	if not general or not general.args then return end

	general.args.warlockSummon = {
		--Between Lua Macros (5.8) and Chat Bubbles (6).
		order = 5.9,
		type = "group",
		name = L["Summon List"],
		args = {
			intro = {
				order = 1,
				type = "description",
				name = L["A raider types the trigger word in chat and every warlock in the raid gets a clickable row. Left-click summons them, Ctrl-click only targets them, right-click drops the row. Summoning takes the row off everyone's list."]
			},
			enable = {
				order = 2,
				type = "toggle",
				name = L["Enable"],
				get = function() return Store().enable and true or false end,
				set = function(_, value)
					Store().enable = value and true or false
					M:UpdateWarlockSummonList()
				end
			},
			trigger = {
				order = 3,
				type = "input",
				name = L["Trigger"],
				desc = L["The word a raider types to ask for a summon. Matched at the start of the line only."],
				get = function() return Store().trigger end,
				set = function(_, value)
					Store().trigger = (value and value ~= "" and value) or "123"
				end
			},
			announce = {
				order = 4,
				type = "select",
				name = L["Announce In"],
				desc = L["Where the summon is announced. Say reaches the people standing at the stone, which is usually who needs to see it."],
				values = { SAY = L["Say"], RAID = L["Raid"], NONE = L["None"] },
				get = function() return Store().announce end,
				set = function(_, value) Store().announce = value end
			},
			whisper = {
				order = 5,
				type = "toggle",
				name = L["Whisper Target"],
				desc = L["Also whispers the person being summoned, so they know to click."],
				get = function() return Store().whisper and true or false end,
				set = function(_, value) Store().whisper = value and true or false end
			},
			zone = {
				order = 6,
				type = "toggle",
				name = L["Include Zone"],
				desc = L["Adds where you are summoning to, which is the one thing a raider cannot see from the dialog."],
				get = function() return Store().zone and true or false end,
				set = function(_, value) Store().zone = value and true or false end
			},
			shards = {
				order = 7,
				type = "toggle",
				name = L["Include Shard Count"],
				desc = L["Adds how many soul shards you have left to the announcement."],
				get = function() return Store().shards and true or false end,
				set = function(_, value) Store().shards = value and true or false end
			},
			sound = {
				order = 8,
				type = "toggle",
				name = L["Sound On Request"],
				desc = L["Plays a sound when somebody joins the list."],
				get = function() return Store().sound and true or false end,
				set = function(_, value) Store().sound = value and true or false end
			},
			soundFile = {
				order = 9,
				type = "select",
				dialogControl = "LSM30_Sound",
				name = L["Alert Sound"],
				desc = L["Which sound. The dropdown plays each one as you move through it, which is the only reliable way to hear what a file does on this client."],
				--The widget library builds this global; Config loads long before Initialize
				--runs, so it is here. Guarded anyway, because a nil values table takes the
				--whole options tree down rather than just this one widget.
				values = AceGUIWidgetLSMlists and AceGUIWidgetLSMlists.sound or {},
				disabled = function() return not Store().sound end,
				get = function() return Store().soundFile end,
				set = function(_, value)
					Store().soundFile = value
					M:PlayWarlockSummonAlert()
				end
			},
			move = {
				order = 10,
				type = "description",
				name = L["Use /moveui to position the list. /octoui-summon shows it and reports who is waiting."]
			}
		}
	}
end

function M:LoadWarlockSummon()
	--Warlock only, and this is where that is enforced: no frame, no mover, no options page
	--and no sitting on six chat events for a character that can never cast the spell.
	--Compared against the English token rather than the localised class name the original
	--used, which was never true on a non-English client.
	if E.myclass ~= "WARLOCK" then return end

	Store()

	--Anchored by its TOP because rows hang downward from it: anchor the other edge and the
	--list grows in both directions as it fills. Same reason as Modules\Misc\CCWatch.lua.
	holder = CreateFrame("Frame", "OctoUI_WarlockSummonHolder", E.UIParent)
	E:Size(holder, ROW_WIDTH, ROW_HEIGHT)
	E:Point(holder, "TOP", E.UIParent, "TOP", 0, -260)
	holder:Hide()

	--Its own frame rather than M:RegisterEvent: Misc already owns events on the module and
	--AceEvent keeps one callback per event per object.
	local events = CreateFrame("Frame")
	events:RegisterEvent("CHAT_MSG_ADDON")
	events:RegisterEvent("CHAT_MSG_SAY")
	events:RegisterEvent("CHAT_MSG_YELL")
	events:RegisterEvent("CHAT_MSG_WHISPER")
	events:RegisterEvent("CHAT_MSG_RAID")
	events:RegisterEvent("CHAT_MSG_RAID_LEADER")
	events:RegisterEvent("RAID_ROSTER_UPDATE")
	events:RegisterEvent("PARTY_MEMBERS_CHANGED")
	events:SetScript("OnEvent", OnEvent)

	BuildOptions()

	--After the SetPoint above and after E.db is loaded, because CreateMover reads the
	--frame's current point as the mover's default.
	E:CreateMover(holder, "WarlockSummonMover", L["Summon List"])
end
