local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, ipairs, type, tonumber, next = pairs, ipairs, type, tonumber, next
local getn, tinsert, sort = table.getn, table.insert, table.sort
local format, lower, gsub, find = string.format, string.lower, string.gsub, string.find
--WoW API / Variables
local CreateFrame = CreateFrame
local GetTime = GetTime
local GetItemInfo = GetItemInfo
local GetLootRollItemInfo = GetLootRollItemInfo
local GetLootRollItemLink = GetLootRollItemLink
local RollOnLoot = RollOnLoot

--[[
	Per-item loot roll rules -- need, greed or pass on the items you name, and nothing at
	all on the ones you do not.

	NOT ON THE LIST MEANS NOT AUTOMATIC. There is no attempt to guess from quality, slot
	or whether you can equip it; an item you did not name is left entirely to you, which
	is the only behaviour that cannot surprise you at the wrong moment.

	ITS OWN EVENT FRAME, not M:RegisterEvent. Misc already owns CHAT_MSG_LOOT -- LootRoll
	counts other players' rolls with it -- and AceEvent keeps one callback per event per
	object, so registering it here would silently replace that counter. Its own frame also
	means the rules keep working with the custom roll bar turned off, since they never
	touch it.

	RULES BEAT THE BLANKET AUTO-GREED. LootRoll greeds every green at max level, and if
	both fired for one rollID they would both call RollOnLoot for it. LootRoll asks
	GetAutoRollRule first and stands down when a rule matches, so exactly one roll is
	ever sent.

	MATCHED BY ID FIRST, THEN BY NAME. An id is exact and survives a renamed item; a name
	is what you can actually type, and what you are left with for a server-added item this
	client cannot look up. Both are stored as keys, so matching a roll is two table reads
	rather than a walk of the list.

	AUTO-REMOVE IS PER ENTRY. A dungeon drop you need once should leave the list the
	moment you win it, but a reputation item drops all night and has to stay. One list
	holds both, so the choice belongs to the entry -- the option only decides what new
	entries inherit.
]]

local ROLL_PASS = 0
local ACTION_ROLLTYPE = {need = 1, greed = 2, pass = ROLL_PASS}

--Chat events a win line might arrive on. See the note in LoadAutoRoll for why this is a
--list rather than CHAT_MSG_LOOT alone.
local WIN_EVENTS = {"CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_MISC_INFO"}

--The client's own words for the three buttons, read when asked rather than at file scope,
--and only ever used for display. Through E:SafeString because these reach the options
--tree, and another addon clobbering a bare CAPS global with a table takes the whole tree
--down with it -- see the note above E:SafeString in Core/core.lua.
local function ActionLabel(action)
	if action == "need" then return E:SafeString(NEED, L["Need"]) end
	if action == "greed" then return E:SafeString(GREED, L["Greed"]) end
	if action == "pass" then return E:SafeString(PASS, L["Pass"]) end
	return action or "?"
end

--No `sorting` key alongside these: this AceConfig revision validates select against
--values/style/control only and raises "unknown parameter" on anything else, taking the
--whole options window down with it. The dialog sorts the keys itself, so the dropdown
--reads Greed, Need, Pass.
local function ActionValues()
	return {need = ActionLabel("need"), greed = ActionLabel("greed"), pass = ActionLabel("pass")}
end

--Rolls we sent ourselves, keyed by rollID, so the confirmation popup for a BoP item can
--be answered without also answering one you opened by hand.
local pendingRolls = {}

--Items we rolled for and have not seen land yet, keyed the same way as the rules. This is
--what makes auto-remove specific: winning is not the only way an item reaches your bags,
--and picking one up off the ground should not quietly edit your list.
local recentRolls = {}

local autoRollFrame
local winPatterns = {}
local winSources = {}

--Declared here rather than beside the sound hook further down, because AutoRollOnStart
--sets silenceRoll and a local declared after that function would not be the one it writes
--to -- the assignment would quietly land on a global and the hook would never see it.
local silenceRoll
local lastSilenced

local function Store()
	local db = E.db.general
	if not db.autoRollRules then
		db.autoRollRules = {}
	end

	local rules = db.autoRollRules
	if rules.enable == nil then rules.enable = true end
	if rules.autoRemove == nil then rules.autoRemove = true end
	if rules.silence == nil then rules.silence = true end
	if not ACTION_ROLLTYPE[rules.newAction] then rules.newAction = "need" end
	if not rules.rules then rules.rules = {} end

	--Every entry carries the key it is stored under, and several paths index by it --
	--`recentRolls[rule.key] = ...` raises on a nil index rather than misbehaving quietly.
	--Cheap to keep true for a list this size, and it means an entry added to the saved
	--variables by hand cannot break a roll later.
	for key, rule in pairs(rules.rules) do
		if rule.key ~= key then rule.key = key end
	end

	return rules
end

--Prefixed so an item literally named "12345" cannot collide with item id 12345.
local function IDKey(id) return "id:"..id end
local function NameKey(name) return "name:"..lower(name) end

local function LinkID(link)
	if not link then return nil end
	local _, _, id = find(link, "item:(%d+)")
	return id and tonumber(id) or nil
end

local function LinkName(link)
	if not link then return nil end
	local _, _, name = find(link, "%[(.-)%]")
	return name
end

--An id with no name is normal rather than broken: this client only knows the items it has
--seen, and everything the server added above 24283 is unknown until one drops. Resolved
--again on each read and written back once it works, so a list built from ids turns into a
--list of names by itself.
function M:AutoRollLabel(rule)
	if not rule then return "?" end

	if not rule.name and rule.id then
		local name = GetItemInfo(rule.id)
		if name and name ~= "" then rule.name = name end
	end

	if rule.name then return rule.name end
	return format(L["AUTOROLL_ITEM_ID"], rule.id or 0)
end

--Accepts a shift-clicked item link, a bare item id, or a name typed by hand. Returns the
--id and the name, either of which may be nil.
function M:ParseAutoRollItem(text)
	if type(text) ~= "string" then return nil, nil end

	text = gsub(text, "^%s+", "")
	text = gsub(text, "%s+$", "")
	if text == "" then return nil, nil end

	local id = LinkID(text)
	if id then
		return id, LinkName(text)
	end

	if find(text, "^%d+$") then
		local numeric = tonumber(text)
		--Deliberately not tail-called: GetItemInfo returns nine values and all nine would
		--end up in the return.
		local name = GetItemInfo(numeric)
		if name == "" then name = nil end
		return numeric, name
	end

	return nil, text
end

function M:GetAutoRollRuleKey(text)
	local id, name = M:ParseAutoRollItem(text)
	if id then return IDKey(id), id, name end
	if name then return NameKey(name), nil, name end
	return nil
end

function M:AddAutoRollRule(text, action, autoRemove)
	local key, id, name = M:GetAutoRollRuleKey(text)
	if not key then return nil end

	local db = Store()
	if not ACTION_ROLLTYPE[action] then action = db.newAction end

	local existing = db.rules[key]

	--Explicit nil tests rather than `or`: false is a meaningful value here, and an entry
	--edited for its action must keep the auto-remove choice already made for it.
	local remove
	if autoRemove ~= nil then
		remove = autoRemove and true or false
	elseif existing then
		remove = existing.autoRemove and true or false
	else
		remove = db.autoRemove and true or false
	end

	db.rules[key] = {
		key = key,
		id = id,
		name = name or (existing and existing.name),
		action = action,
		autoRemove = remove
	}

	return db.rules[key]
end

function M:RemoveAutoRollRule(text)
	local key = M:GetAutoRollRuleKey(text)
	if not key then return nil end

	local db = Store()
	local rule = db.rules[key]
	if not rule then return nil end

	db.rules[key] = nil
	recentRolls[key] = nil

	return rule
end

function M:SetAutoRollRemove(text, remove)
	local key = M:GetAutoRollRuleKey(text)
	if not key then return nil end

	local rule = Store().rules[key]
	if not rule then return nil end

	rule.autoRemove = remove and true or false
	return rule
end

--For /octoui-roll, which needs the settings themselves rather than the list. Goes through
--Store so the command sees the same normalised table the options page does.
function M:GetAutoRollSettings()
	return Store()
end

--Sorted, because an unsorted list of thirty items is not something anyone can read.
--
--Labels are resolved BEFORE the sort, not inside the comparator: AutoRollLabel caches a
--name the first time the client can supply one, so an id resolving mid-sort would change
--the ordering underneath the algorithm and Lua raises "invalid order function" for that.
function M:GetAutoRollRules()
	local list, labels = {}, {}
	for _, rule in pairs(Store().rules) do
		tinsert(list, rule)
		labels[rule] = lower(M:AutoRollLabel(rule))
	end

	sort(list, function(a, b) return labels[a] < labels[b] end)
	return list
end

--An entry only counts as a match if it names a roll we can actually cast. LootRoll retires
--its bar on the strength of this answer, so a rule with an action that survived a hand
--edit of the saved variables must read as no rule at all rather than as a bar hidden for a
--roll that was never sent.
local function Usable(rule)
	if rule and ACTION_ROLLTYPE[rule.action] ~= nil then return rule end
	return nil
end

--The lookup LootRoll also calls, so it can stand its own auto-greed down and drop the bar.
--Order-independent on purpose: both handlers see the same START_LOOT_ROLL and either may
--run first, so this answers "is there a rule for this" rather than "has one rolled yet".
function M:GetAutoRollRule(rollID)
	local db = Store()
	if not db.enable then return nil end
	if not next(db.rules) then return nil end

	local id = LinkID(GetLootRollItemLink(rollID))
	if id then
		local rule = Usable(db.rules[IDKey(id)])
		if rule then return rule end
	end

	local _, name = GetLootRollItemInfo(rollID)
	if name and name ~= "" then
		local rule = Usable(db.rules[NameKey(name)])
		if rule then return rule end
	end

	return nil
end

local function Prune(now)
	--Assigning nil to the key pairs() is currently on is the one mutation the iterator
	--allows, so this needs no second pass.
	for rollID, pending in pairs(pendingRolls) do
		if pending.expires < now then pendingRolls[rollID] = nil end
	end
	for key, expires in pairs(recentRolls) do
		if expires < now then recentRolls[key] = nil end
	end
end

function M:AutoRollOnStart(rollID, duration)
	if not rollID then return end

	local now = GetTime()
	Prune(now)

	local rule = M:GetAutoRollRule(rollID)
	if not rule then return end

	local rolltype = ACTION_ROLLTYPE[rule.action]
	if rolltype == nil then return end

	--A roll is the one moment a server item's name is certain to be available, so an entry
	--added as a bare id learns it here instead of reading "Item #24601" forever. It also
	--gives the win line something to match against when that line carries a name and no id.
	if not rule.name then
		local _, rolledName = GetLootRollItemInfo(rollID)
		if rolledName and rolledName ~= "" then rule.name = rolledName end
	end

	--arg2 is the roll's length -- milliseconds on every 1.12 client seen, but a value that
	--small could only be seconds, so both read the same rather than one being assumed. The
	--window is that plus a margin for the server to answer, and it only has to outlive one
	--roll: a rule that never wins simply expires and is asked again next time.
	local window = tonumber(duration) or 60
	if window > 1000 then window = window / 1000 end
	window = window + 30
	pendingRolls[rollID] = {rolltype = rolltype, key = rule.key, expires = now + window}

	if rolltype ~= ROLL_PASS then
		recentRolls[rule.key] = now + window
	end

	silenceRoll = now
	RollOnLoot(rollID, rolltype)
	silenceRoll = nil

	--The roll bar has nothing left to ask once this has answered it. Guarded and repeated
	--on LootRoll's side: whichever of the two handlers runs second is the one that finds a
	--bar to retire.
	if M.RetireRollBar then M:RetireRollBar(rollID) end

	local link = GetLootRollItemLink(rollID)
	E:Print(format(L["AUTOROLL_ROLLED"], ActionLabel(rule.action), link or M:AutoRollLabel(rule)))
end

--Rolling Need or Greed on a bind-on-pickup item raises a confirmation, which would leave
--the automation half done. Answered only for the roll we sent and only with the choice we
--sent, so a roll you are deciding by hand is never answered for you.
function M:ConfirmAutoRoll(rollID, rolltype)
	local pending = rollID and pendingRolls[rollID]
	if not pending or pending.rolltype ~= rolltype then return end
	if type(ConfirmLootRoll) ~= "function" then return end

	ConfirmLootRoll(rollID, rolltype)
	M:HideRollPopup(rollID)

	--Again a moment later: the dialog is Blizzard's and whether it exists yet depends on
	--which frame the client hands the event to first.
	E:Delay(0.05, function() M:HideRollPopup(rollID) end)
end

--Only the dialog carrying this rollID. Hiding every CONFIRM_LOOT_ROLL would take a second
--roll's dialog away from you mid-decision.
function M:HideRollPopup(rollID)
	local count = STATICPOPUP_NUMDIALOGS or 4
	for i = 1, count do
		local dialog = getglobal("StaticPopup"..i)
		if dialog and dialog:IsShown() and dialog.which == "CONFIRM_LOOT_ROLL" and dialog.data == rollID then
			dialog:Hide()
		end
	end
end

--[[
	The noise a roll makes.

	A bind-on-pickup roll raises Blizzard's CONFIRM_LOOT_ROLL dialog, and a static popup
	plays igMainMenuOpen from its OnShow -- the port of that file does the same at
	Core/StaticPopups.lua:496, which is the best evidence available here for what the
	original does. So the clunk is the dialog arriving, and hiding it a frame later cannot
	unring it: the sound is already out by then.

	Silenced by swallowing the PlaySound belonging to our own roll and nothing else. Two
	narrow windows only -- the RollOnLoot call itself, and the client's dispatch of a
	confirmation for a rollID we sent -- and at most one sound per roll, so a sound that
	merely lands in the same instant still plays.

	Whatever gets swallowed is recorded and reported by /octoui-roll. If that ever reads
	"nothing", the noise comes from the client rather than from Lua and no addon can take
	it away.
]]
local function ShouldSilence()
	if not Store().silence then return false end

	--Time-bounded rather than a plain flag: an error inside RollOnLoot would leave a bare
	--flag set and mute the entire UI for the session.
	if silenceRoll and (GetTime() - silenceRoll) < 1 then return true end

	--`event` and `arg1` are the client's event globals, still current while the
	--confirmation is being dispatched -- which is where the dialog, and its sound, come
	--from. Marked on the pending roll so this can only ever swallow one sound per roll,
	--rather than staying armed on a stale `event` once dispatch has finished.
	if event == "CONFIRM_LOOT_ROLL" and arg1 then
		local pending = pendingRolls[arg1]
		if pending and not pending.silenced then
			pending.silenced = true
			return true
		end
	end

	return false
end

local function PlaySoundHook(sound, channel)
	if ShouldSilence() then
		lastSilenced = sound
		return
	end

	return E.hooks.PlaySound(sound, channel)
end

function M:GetAutoRollSilenced()
	return lastSilenced
end

--[[
	Winning is read from the client's own loot messages rather than a wording written out
	here: LOOT_ITEM_SELF and friends are already in whatever locale the client is running,
	and turning them into patterns means this cannot drift from what the game actually
	prints. Whichever of them this client defines is what gets used, and /octoui-roll says
	which those were -- if none of them exist, rolling still works and only auto-remove
	goes quiet.
]]
local function ToPattern(str)
	str = gsub(str, "([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
	str = gsub(str, "%%%%s", "(.+)")
	str = gsub(str, "%%%%d", "%%d+")
	return "^"..str
end

local function AddWinPattern(pattern, source)
	--The globals and the literals below can describe the same line, so a pattern already
	--held is not added twice and the report stays readable.
	for _, existing in ipairs(winPatterns) do
		if existing == pattern then return end
	end

	tinsert(winPatterns, pattern)
	tinsert(winSources, source)
end

local function BuildWinPatterns()
	winPatterns = {}
	winSources = {}

	--Multiple first: its capture stops at the count, where the single-item pattern would
	--swallow it. Both still yield the same id, but the tighter match is the better one.
	local sources = {
		{name = "LOOT_ITEM_SELF_MULTIPLE", text = LOOT_ITEM_SELF_MULTIPLE},
		{name = "LOOT_ITEM_SELF", text = LOOT_ITEM_SELF},
		{name = "LOOT_ROLL_YOU_WON", text = LOOT_ROLL_YOU_WON}
	}

	for _, source in ipairs(sources) do
		if type(source.text) == "string" and source.text ~= "" and find(source.text, "%%s") then
			AddWinPattern(ToPattern(source.text), source.name)
		end
	end

	--Wordings read off this server on 2026-08-12, for the case where the global behind one
	--of them does not exist -- this realm prints its own roll lines ("Need Roll - 42 for
	--[Item] by Name"), so the win line is not certain to be Blizzard's either. English
	--only and deliberately last: any client that defines the globals matches on those
	--first, in whatever locale it is running.
	AddWinPattern("^You won: (.+)", "observed 'You won:'")
	AddWinPattern("^You receive loot: (.+)%.", "observed 'You receive loot:'")
end

function M:GetAutoRollWinSources()
	return winSources
end

function M:GetAutoRollWinEvents()
	return WIN_EVENTS
end

local function ConsumeWin(key, text)
	if not recentRolls[key] then return false end
	recentRolls[key] = nil

	local db = Store()
	local rule = db.rules[key]
	if rule and rule.autoRemove then
		local label = M:AutoRollLabel(rule)
		db.rules[key] = nil
		E:Print(format(L["AUTOROLL_REMOVED"], text or label))
		M:ScheduleAutoRollRefresh()
	end

	return true
end

function M:AutoRollItemReceived(text)
	local id, name = LinkID(text), LinkName(text)

	if id and ConsumeWin(IDKey(id), text) then return end
	if name and ConsumeWin(NameKey(name), text) then return end
	if not name then return end

	--Last resort: an entry added as an id, against a win line carrying only a name. The
	--roll itself taught the entry its name, so compare on that. Only rolls still in flight
	--are looked at, which is a handful of keys at the very most.
	local wanted = lower(name)
	local rules = Store().rules
	for key in pairs(recentRolls) do
		local rule = rules[key]
		if rule and lower(M:AutoRollLabel(rule)) == wanted then
			ConsumeWin(key, text)
			return
		end
	end
end

local function OnLootMessage(msg)
	if type(msg) ~= "string" then return end
	if not next(recentRolls) then return end

	Prune(GetTime())

	for _, pattern in ipairs(winPatterns) do
		local _, _, captured = find(msg, pattern)
		if captured then
			M:AutoRollItemReceived(captured)
			return
		end
	end
end

--[[
	The options page.

	Built here rather than in Config/ for the same reason Blacklist is: Config files are
	read from the .toc at process start, so a change there needs a full exit of the client
	while a change here needs only /reload. E.Options is populated by then, which is why
	this runs from LoadAutoRoll and not at file scope.
]]
local refreshPending

--Never rebuild the options tree from inside a widget callback -- AceConfigDialog is still
--unwinding the click and returns to a group this would have deleted underneath it. Every
--path goes through here, coalesced, and rebuilds on a later frame.
function M:ScheduleAutoRollRefresh()
	if refreshPending then return end
	refreshPending = true

	E:Delay(0.05, function()
		refreshPending = nil
		M:RefreshAutoRollOptions()

		local ACR = LibStub and LibStub("AceConfigRegistry-3.0", true)
		if ACR and E.ConfigAppName then
			pcall(ACR.NotifyChange, ACR, E.ConfigAppName)
		end
	end)
end

local staticArgs = {intro = true, enable = true, autoRemove = true, silence = true, newAction = true, add = true}

function M:RefreshAutoRollOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	local group = general and general.args and general.args.lootRules
	if not group then return end

	local args = group.args
	for key in pairs(args) do
		if not staticArgs[key] then args[key] = nil end
	end

	local list = M:GetAutoRollRules()
	if getn(list) == 0 then
		args.empty = {
			order = 10,
			type = "description",
			name = L["Nothing on the list. Every roll is left to you until you add something."]
		}
		return
	end

	for index, rule in ipairs(list) do
		local key = rule.key
		args["rule"..index] = {
			order = 10 + index,
			type = "group",
			guiInline = true,
			name = M:AutoRollLabel(rule),
			args = {
				action = {
					order = 1,
					type = "select",
					name = L["Roll"],
					values = ActionValues(),
					get = function()
						local entry = Store().rules[key]
						return entry and entry.action or "need"
					end,
					set = function(_, value)
						local entry = Store().rules[key]
						if entry then entry.action = value end
					end
				},
				autoRemove = {
					order = 2,
					type = "toggle",
					name = L["Remove after winning"],
					desc = L["Takes this off the list once the item reaches you. Turn it off for something that drops again and again, like a reputation turn-in."],
					get = function()
						local entry = Store().rules[key]
						return entry and entry.autoRemove or false
					end,
					set = function(_, value)
						local entry = Store().rules[key]
						if entry then entry.autoRemove = value and true or false end
					end
				},
				remove = {
					order = 3,
					type = "execute",
					name = L["Remove"],
					desc = L["Takes this off the list. Rolls for it go back to being yours to make."],
					func = function()
						Store().rules[key] = nil
						recentRolls[key] = nil
						M:ScheduleAutoRollRefresh()
					end
				}
			}
		}
	end
end

local function BuildOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	if not general or not general.args then return end

	general.args.lootRules = {
		order = 5,
		type = "group",
		name = L["Loot Rolls"],
		args = {
			intro = {
				order = 1,
				type = "description",
				name = L["Rolls need, greed or pass for you on the items named here. Anything not on the list is left alone. Paste an item link, an item id, or type a name."]
			},
			enable = {
				order = 2,
				type = "toggle",
				name = L["Enable"],
				desc = L["Turns every rule below off at once without losing the list."],
				get = function() return Store().enable and true or false end,
				set = function(_, value) Store().enable = value and true or false end
			},
			autoRemove = {
				order = 3,
				type = "toggle",
				name = L["Remove after winning"],
				desc = L["What new entries start with. Each entry keeps its own setting afterwards."],
				get = function() return Store().autoRemove and true or false end,
				set = function(_, value) Store().autoRemove = value and true or false end
			},
			silence = {
				order = 3.5,
				type = "toggle",
				name = L["Silence the confirmation"],
				desc = L["A bind-on-pickup roll raises a confirmation dialog, and the sound it makes is the clunk you hear. This swallows that one sound, for automatic rolls only."],
				get = function() return Store().silence and true or false end,
				set = function(_, value) Store().silence = value and true or false end
			},
			newAction = {
				order = 4,
				type = "select",
				name = L["Roll"],
				desc = L["What new entries start with."],
				values = ActionValues(),
				get = function() return Store().newAction end,
				set = function(_, value) Store().newAction = value end
			},
			add = {
				order = 5,
				type = "input",
				width = "full",
				name = L["Add item"],
				desc = L["An item link, an item id, or a name. Shift-clicking an item into the box is the safest of the three."],
				get = function() return "" end,
				set = function(_, value)
					if value and value ~= "" then
						M:AddAutoRollRule(value)
						M:ScheduleAutoRollRefresh()
					end
				end
			}
		}
	}

	M:RefreshAutoRollOptions()
end

function M:LoadAutoRoll()
	Store()
	BuildWinPatterns()
	BuildOptions()

	--Installed once and gated by the option from inside, rather than hooked and unhooked as
	--the option moves: two comparisons per UI sound is cheaper than that bookkeeping, and a
	--hook that is never removed cannot be removed at the wrong moment either. On E rather
	--than on Misc because Misc does not embed AceHook and E does.
	if not E.hooks.PlaySound then
		E:RawHook("PlaySound", PlaySoundHook, true)
	end

	autoRollFrame = CreateFrame("Frame")
	autoRollFrame:RegisterEvent("START_LOOT_ROLL")
	autoRollFrame:RegisterEvent("CONFIRM_LOOT_ROLL")

	--Every event a "You won:" line could arrive on rather than the one it ought to. This
	--realm prints its own roll announcements and they land in the combat log, so which
	--channel carries the win is not something to assume -- and RegisterEvent accepts a
	--name this client does not have without complaining, so a wrong guess here costs
	--nothing. The handler leaves immediately unless a roll of ours is actually in flight,
	--which is what keeps the noisy ones cheap.
	for _, chatEvent in ipairs(WIN_EVENTS) do
		autoRollFrame:RegisterEvent(chatEvent)
	end

	autoRollFrame:SetScript("OnEvent", function()
		if event == "START_LOOT_ROLL" then
			M:AutoRollOnStart(arg1, arg2)
		elseif event == "CONFIRM_LOOT_ROLL" then
			M:ConfirmAutoRoll(arg1, arg2)
		else
			OnLootMessage(arg1)
		end
	end)
end
