local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, ipairs, type = pairs, ipairs, type
local getn, tinsert, sort = table.getn, table.insert, table.sort
local format, lower = string.format, string.lower
local date = date
--WoW API / Variables
local CreateFrame = CreateFrame
local UnitName = UnitName
local GetNumPartyMembers, GetNumRaidMembers = GetNumPartyMembers, GetNumRaidMembers

--[[
	Notes on the game's own ignore list, and a private warning when one of them turns up
	in your group.

	THE IGNORE LIST IS THE BLACKLIST. An earlier version of this kept a separate list of
	names, which was a mistake: it meant adding someone twice, and two lists that drift
	apart the moment you use /ignore like a normal person. Membership belongs to the
	client -- /ignore adds, /unignore removes, and the server keeps it. All this module
	adds is the one thing the game does not: WHY.

	That is the part worth having. A name on a list is useless a month later; nobody
	remembers whether it was a ninja looter, a bad tank, or someone rude once, and those
	deserve different reactions. The note and the date sit beside the warning so the
	decision is yours.

	DISCREET BY DESIGN. It prints to your own chat frame and nowhere else -- no group
	chat, no emote, no raid warning, nothing anyone else can see. The point is to let you
	decide whether to stay, not to accuse someone in front of four strangers. Anything
	that announced itself would turn a private judgement into a public one.

	Storage note: the ignore list is PER CHARACTER (the server keeps it that way), but the
	notes live in E.global, which is per account. That asymmetry is deliberate -- a ninja
	looter is the same person whichever of your characters met them, so the note should
	follow you even though the ignore itself does not.

	Fires on the TRANSITION, not the state, so a dungeon group filling up gives one line
	per player rather than one per roster change.
]]

local warned = {}
local blacklistFrame

local function Key(name)
	return name and lower(name) or nil
end

local function Store()
	if not E.global.blacklist then
		E.global.blacklist = {enable = true, notes = {}}
	end
	if not E.global.blacklist.notes then
		E.global.blacklist.notes = {}
	end

	--Carry over anything the earlier parallel-list version recorded, so a note written
	--before this rewrite is not silently dropped.
	if E.global.blacklist.players then
		for key, entry in pairs(E.global.blacklist.players) do
			if not E.global.blacklist.notes[key] then
				E.global.blacklist.notes[key] = {reason = entry.reason, added = entry.added}
			end
		end
		E.global.blacklist.players = nil
	end

	return E.global.blacklist
end

--Guarded rather than assumed. Nothing in this codebase used the ignore API before, so it
--was unverified on this client; /oprobe api reports it under "ignore".
function M:IgnoreAPIPresent()
	return type(GetNumIgnores) == "function" and type(GetIgnoreName) == "function"
end

--The list the game holds, with our notes attached. Sorted, because an unsorted list of
--thirty names is not something anyone can read.
function M:GetIgnoreList()
	local list = {}
	if not M:IgnoreAPIPresent() then return list end

	local notes = Store().notes
	for i = 1, GetNumIgnores() do
		local name = GetIgnoreName(i)
		--A freshly added entry can read as UNKNOWN until the server answers.
		if name and name ~= "" and name ~= UNKNOWNOBJECT then
			local note = notes[Key(name)]
			tinsert(list, {
				name = name,
				reason = note and note.reason,
				added = note and note.added
			})
		end
	end

	sort(list, function(a, b) return lower(a.name) < lower(b.name) end)
	return list
end

function M:GetBlacklistNote(name)
	local key = Key(name)
	if not key then return nil end
	return Store().notes[key]
end

function M:SetBlacklistNote(name, reason)
	local key = Key(name)
	if not key then return nil end

	local notes = Store().notes
	if not reason or reason == "" then
		notes[key] = nil
		return nil
	end

	notes[key] = {
		reason = reason,
		--Kept from the first entry: when they earned it matters more than when the note
		--was last reworded.
		added = (notes[key] and notes[key].added) or date("%Y-%m-%d")
	}

	--So editing a note while grouped with them warns again with the new wording.
	warned[key] = nil

	return notes[key]
end

--Removes from the game's list. The note is kept deliberately: un-ignoring someone is not
--the same as deciding you were wrong about them, and if they end up back on the list the
--history is still there.
function M:RemoveFromIgnore(name)
	if not name or name == "" then return false end
	if type(DelIgnore) ~= "function" then return false end

	DelIgnore(name)
	warned[Key(name)] = nil
	return true
end

function M:AddToIgnore(name, reason)
	if not name or name == "" then return false end
	if type(AddIgnore) ~= "function" then return false end

	AddIgnore(name)
	if reason and reason ~= "" then
		M:SetBlacklistNote(name, reason)
	end
	return true
end

local function IgnoredSet()
	local ignored = {}
	if not M:IgnoreAPIPresent() then return ignored end

	for i = 1, GetNumIgnores() do
		local name = GetIgnoreName(i)
		if name and name ~= "" then ignored[Key(name)] = name end
	end
	return ignored
end

local function GroupMembers()
	local members = {}

	local raid = GetNumRaidMembers()
	if raid > 0 then
		for i = 1, raid do
			local name = UnitName("raid"..i)
			if name then members[Key(name)] = name end
		end
		return members
	end

	for i = 1, GetNumPartyMembers() do
		local name = UnitName("party"..i)
		if name then members[Key(name)] = name end
	end

	return members
end

function M:CheckGroupForBlacklisted()
	local db = Store()
	if db.enable == false then return end
	if not M:IgnoreAPIPresent() then return end

	local members = GroupMembers()
	local ignored = IgnoredSet()

	--Drop anyone no longer here first, so a rejoin warns again.
	for key in pairs(warned) do
		if not members[key] then warned[key] = nil end
	end

	for key, displayName in pairs(members) do
		if ignored[key] and not warned[key] then
			warned[key] = true

			local note = db.notes[key]
			if note and note.reason then
				E:Print(format("|cffff3333On your ignore list:|r %s -- %s |cff888888(noted %s)|r",
					displayName, note.reason, note.added or "?"))
			else
				E:Print(format("|cffff3333On your ignore list:|r %s |cff888888(no reason recorded -- /octoui-blacklist note %s <why>)|r",
					displayName, displayName))
			end
		end
	end
end

--[[
	The options page.

	Built here rather than in Config/ because Config files are read from the .toc at
	process start, and adding one would need a full exit of WoW.exe. This file already
	exists, so building the page from it means a /reload is enough. E.Options is populated
	by the time Initialize runs, which is why this is called from LoadBlacklist and not at
	file scope.

	Rebuilt on IGNORELIST_UPDATE because the list is the game's, not ours -- somebody
	typing /ignore in chat has to show up here without reopening the window.
]]
--[[
	Never rebuild the options tree from inside a widget callback.

	The Un-ignore button did, and AceConfigDialog raised at AceConfigDialog-3.0.lua:676
	with "attempt to index local `group'": it was still unwinding the click and went to
	return to the group the button lived in, which the rebuild had just deleted underneath
	it. DelIgnore makes it worse by firing IGNORELIST_UPDATE, so the tree was being torn
	down twice inside one click.

	So every path goes through here instead, and the rebuild happens on the next frame with
	the click finished. Coalesced, because the button press and the event it causes would
	otherwise queue two.
]]
local refreshPending

function M:ScheduleBlacklistRefresh()
	if refreshPending then return end
	refreshPending = true

	E:Delay(0.05, function()
		refreshPending = nil
		M:RefreshBlacklistOptions()

		--Tell the open window its contents moved, or it keeps drawing the old rows.
		local ACR = LibStub and LibStub("AceConfigRegistry-3.0", true)
		if ACR and E.ConfigAppName then
			pcall(ACR.NotifyChange, ACR, E.ConfigAppName)
		end
	end)
end

function M:RefreshBlacklistOptions()
	local group = E.Options and E.Options.args and E.Options.args.blacklist
	if not group then return end

	local args = group.args
	for key in pairs(args) do
		if key ~= "intro" and key ~= "warn" and key ~= "add" then args[key] = nil end
	end

	if not M:IgnoreAPIPresent() then
		args.unavailable = {
			order = 10,
			type = "description",
			name = L["This client does not provide the ignore list API, so nothing can be shown here."]
		}
		return
	end

	local list = M:GetIgnoreList()
	if getn(list) == 0 then
		args.empty = {
			order = 10,
			type = "description",
			name = L["Your ignore list is empty. Use /ignore <name> in game, then add a note here."]
		}
		return
	end

	for index, entry in ipairs(list) do
		local name = entry.name
		args["player"..index] = {
			order = 10 + index,
			type = "group",
			guiInline = true,
			name = name,
			args = {
				reason = {
					order = 1,
					type = "input",
					width = "full",
					name = L["Reason"],
					desc = entry.added and format(L["Noted %s"], entry.added) or L["Why this player is on your list."],
					get = function()
						local note = M:GetBlacklistNote(name)
						return note and note.reason or ""
					end,
					set = function(_, value)
						M:SetBlacklistNote(name, value)
						M:ScheduleBlacklistRefresh()
					end
				},
				remove = {
					order = 2,
					type = "execute",
					name = L["Un-ignore"],
					desc = L["Removes them from the game's ignore list. The note is kept in case they end up back on it."],
					func = function()
						M:RemoveFromIgnore(name)
						M:ScheduleBlacklistRefresh()
					end
				}
			}
		}
	end
end

local function BuildOptions()
	if not E.Options or not E.Options.args then return end

	E.Options.args.blacklist = {
		type = "group",
		name = L["Ignore List"],
		order = 7,
		args = {
			intro = {
				order = 1,
				type = "description",
				name = L["Notes on the players you have ignored. Membership is the game's own ignore list -- use /ignore and /unignore as normal, and this remembers why."]
			},
			warn = {
				order = 2,
				type = "toggle",
				name = L["Warn me in my group"],
				desc = L["Prints a private line when someone on your ignore list is in your party or raid. Only you ever see it."],
				get = function() return Store().enable ~= false end,
				set = function(_, value) Store().enable = value and true or false end
			},
			add = {
				order = 3,
				type = "input",
				name = L["Ignore a player"],
				desc = L["Same as typing /ignore. Add the reason afterwards below."],
				get = function() return "" end,
				set = function(_, value)
					if value and value ~= "" then
						M:AddToIgnore(value)
						M:ScheduleBlacklistRefresh()
					end
				end
			}
		}
	}

	M:RefreshBlacklistOptions()
end

function M:LoadBlacklist()
	Store()
	BuildOptions()

	blacklistFrame = CreateFrame("Frame")
	blacklistFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
	blacklistFrame:RegisterEvent("RAID_ROSTER_UPDATE")
	--Covers logging in or reloading while already in a group, which neither roster event
	--fires for.
	blacklistFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	--The list is the game's, so it can change without us: /ignore typed in chat, or the
	--server answering a name we only had as UNKNOWN a moment ago.
	blacklistFrame:RegisterEvent("IGNORELIST_UPDATE")

	--Its own frame rather than M:RegisterEvent: Misc.lua already registers
	--PARTY_MEMBERS_CHANGED on this module for AutoInvite, and AceEvent keeps one callback
	--per event per object -- registering here would silently replace it.
	blacklistFrame:SetScript("OnEvent", function()
		if event == "IGNORELIST_UPDATE" then
			M:ScheduleBlacklistRefresh()
		end
		M:CheckGroupForBlacklisted()
	end)
end
