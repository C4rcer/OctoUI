local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB

--Cache global variables
--Lua functions
local _G = _G
local tonumber, type, pairs, ipairs = tonumber, type, pairs, ipairs
local getn, concat = table.getn, table.concat
local format, len, lower, match = string.format, string.len, string.lower, string.match
--WoW API / Variables
local UIFrameFadeOut, UIFrameFadeIn = UIFrameFadeOut, UIFrameFadeIn
local EnableAddOn, DisableAddOn, DisableAllAddOns = EnableAddOn, DisableAddOn, DisableAllAddOns
local SetCVar, GetCVar = SetCVar, GetCVar
local ReloadUI = ReloadUI
local GetAddOnInfo = GetAddOnInfo
local IsAddOnLoaded = IsAddOnLoaded
local GetScreenWidth, GetScreenHeight = GetScreenWidth, GetScreenHeight
local GetPlayerBuff, GetPlayerBuffTexture = GetPlayerBuff, GetPlayerBuffTexture
local GetInventorySlotInfo, GetInventoryItemLink = GetInventorySlotInfo, GetInventoryItemLink
local GetTime = GetTime
local GetNumRaidMembers, GetNumPartyMembers = GetNumRaidMembers, GetNumPartyMembers
local UnitExists, UnitName = UnitExists, UnitName
local UnitDebuff, UnitLevel = UnitDebuff, UnitLevel
local UnitAffectingCombat = UnitAffectingCombat

function E:EnableAddon(addon)
	local _, _, _, _, _, reason, _ = GetAddOnInfo(addon)
	if reason ~= "MISSING" then
		EnableAddOn(addon)
		ReloadUI()
	else
		E:Print(format("Addon '%s' not found.", addon))
	end
end

function E:DisableAddon(addon)
	local _, _, _, _, _, reason, _ = GetAddOnInfo(addon)
	if reason ~= "MISSING" then
		DisableAddOn(addon)
		ReloadUI()
	else
		E:Print(format("Addon '%s' not found.", addon))
	end
end

function FarmMode()
	if E.private.general.minimap.enable ~= true then return end

	if Minimap:IsShown() then
		UIFrameFadeOut(Minimap, 0.3)
		UIFrameFadeIn(FarmModeMap, 0.3)
		Minimap.fadeInfo.finishedFunc = function()
			Minimap:Hide()
			Minimap.backdrop:Hide()
			_G.MinimapZoomIn:Click()
			_G.MinimapZoomOut:Click()
			Minimap:SetAlpha(1)
		end
		FarmModeMap.enabled = true
	else
		UIFrameFadeOut(FarmModeMap, 0.3)
		UIFrameFadeIn(Minimap, 0.3)
		FarmModeMap.fadeInfo.finishedFunc = function()
			FarmModeMap:Hide()
			Minimap.backdrop:Show()
			_G.MinimapZoomIn:Click()
			_G.MinimapZoomOut:Click()
			Minimap:SetAlpha(1)
		end
		FarmModeMap.enabled = false
	end
end

function E:FarmMode(msg)
	if E.private.general.minimap.enable ~= true then return end
	if msg and type(tonumber(msg)) == "number" and tonumber(msg) <= 500 and tonumber(msg) >= 20 then
		E.db.farmSize = tonumber(msg)
		E:Size(FarmModeMap, tonumber(msg))
	end

	FarmMode()
end

function E:Grid(msg)
	msg = msg and tonumber(msg)
	if type(msg) == "number" and (msg <= 256 and msg >= 4) then
		E.db.gridSize = msg
		E:Grid_Show()
	elseif _G.ElvUIGrid and _G.ElvUIGrid:IsShown() then
		E:Grid_Hide()
	else
		E:Grid_Show()
	end
end

function E:LuaError(msg)
	msg = lower(msg)
	if msg == "on" then
		DisableAllAddOns()
		EnableAddOn("OctoUI")
		SetCVar("ShowErrors", 1)
		ReloadUI()
	elseif msg == "off" then
		SetCVar("ShowErrors", 0)
		E:Print("Lua errors off.")
	else
		E:Print("/luaerror on - /luaerror off")
	end
end

function E:BGStats()
	local DT = E:GetModule("DataTexts")
	DT.ForceHideBGStats = nil
	DT:LoadDataTexts()

	E:Print(L["Battleground datatexts will now show again if you are inside a battleground."])
end

local editbox = CreateFrame("Editbox", "MacroEditBox")
editbox:Hide()

local function OnCallback(command)
	local defaulteditbox = ChatFrameEditBox
	MacroEditBox.chatType = defaulteditbox.chatType
	MacroEditBox.tellTarget = defaulteditbox.tellTarget
	MacroEditBox.channelTarget = defaulteditbox.channelTarget
	MacroEditBox:SetText(command)
	ChatEdit_SendText(MacroEditBox)
end

function E:DelayScriptCall(msg)
	local secs, command = match(msg, "^(%S+)%s+(.*)$")
	secs = tonumber(secs)
	if (not secs) or (len(command) == 0) then
		self:Print("usage: /in <seconds> <command>")
		self:Print("example: /in 1.5 /say hi")
	else
		E:Delay(secs, OnCallback, command)
	end
end

local BLIZZARD_ADDONS = {
	"Blizzard_AuctionUI",
	"Blizzard_BattlefieldMinimap",
	"Blizzard_BindingUI",
	"Blizzard_CombatText",
	"Blizzard_CraftUI",
	"Blizzard_GMSurveyUI",
	"Blizzard_InspectUI",
	"Blizzard_MacroUI",
	"Blizzard_RaidUI",
	"Blizzard_TalentUI",
	"Blizzard_TradeSkillUI",
	"Blizzard_TrainerUI"
}

function E:EnableBlizzardAddOns()
	for _, addon in pairs(BLIZZARD_ADDONS) do
		local reason = select(6, GetAddOnInfo(addon)) --reason, not loadable at 5
		if reason == "DISABLED" then
			EnableAddOn(addon)
			E:Print("The following addon was re-enabled:", addon)
		end
	end
end

--Spell queueing is nampower's, not OctoUI's, and it is configured entirely through
--CVars the DLL registers at load. Three things can be wrong and they need telling
--apart: the DLL is not reaching this Lua state at all, it is loaded but the relevant
--queue type is switched off, or it is loaded and queueing fine and the problem lies
--elsewhere. Only the last is invisible without watching the event.
local QUEUE_CVARS = {
	"NP_QueueCastTimeSpells",
	"NP_QueueInstantSpells",
	"NP_QueueChannelingSpells",
	"NP_QueueTargetingSpells",
	"NP_QueueSpellsOnCooldown",
	"NP_QueueOnSwingSpells",
	"NP_SpellQueueWindowMs",
	"NP_ChannelQueueWindowMs",
	"NP_CooldownQueueWindowMs",
}

local QUEUE_API = {"QueueSpellByName", "CastSpellByNameNoQueue", "CastSpellNoQueue", "QueueScript"}

local queueWatcher, queueWatching, queueHooked

--How much of the current cast is left, in seconds, or nil when nothing is casting.
--This is the number that decides whether a press queues, and it is the one thing the
--player cannot see -- "sporadic" is what a 500ms window looks like from the outside.
local function CastRemaining()
	local bar = _G.ElvUF_Player and _G.ElvUF_Player.Castbar
	if not (bar and bar:IsShown()) then return end

	if bar.channeling then
		return bar.value
	elseif bar.casting then
		return (bar.max or 0) - (bar.value or 0)
	end
end

--Logged on the way past, so a press that never queued still leaves a line. The hooks
--stay installed once added -- hooksecurefunc cannot be undone -- so everything they do
--is behind the watching flag.
local function LogCastAttempt(what)
	if not queueWatching then return end

	local remaining = CastRemaining()
	if remaining then
		E:Print(format("press %s with |cffffff00%.2fs|r left on the current cast", what, remaining))
	else
		E:Print(format("press %s (nothing casting)", what))
	end
end

function E:QueueReport()
	local seen = 0
	for i = 1, getn(QUEUE_CVARS) do
		local name = QUEUE_CVARS[i]
		local value = GetCVar(name)
		if value then seen = seen + 1 end

		--"0" is a perfectly ordinary answer and the reason one of these is off by
		--default: on-swing spells do not queue unless asked to
		E:Print(format("%s = %s", name,
			value and ((value == "0") and ("|cffff9900"..value.."|r") or value) or "|cffff0000nil|r"))
	end

	if seen == 0 then
		E:Print("|cffff0000None of nampower's CVars exist|r - the DLL is not in this session. Check dlls.txt and Logs\\nampower_debug.log.")
		return
	end

	local missing = ""
	for i = 1, getn(QUEUE_API) do
		if not _G[QUEUE_API[i]] then
			missing = missing..((missing == "") and "" or ", ")..QUEUE_API[i]
		end
	end
	E:Print(format("nampower Lua API: %s", (missing == "") and "|cff00ff00all present|r" or ("|cffff0000missing "..missing.."|r")))

	--The only actual proof that a press was queued rather than dropped
	if queueWatching then
		queueWatcher:UnregisterAllEvents()
		queueWatching = nil
		E:Print("Queue watch |cffff9900off|r.")
		return
	end

	if not queueWatcher then
		queueWatcher = CreateFrame("Frame", "OctoUI_QueueWatch", E.UIParent)
		queueWatcher:SetScript("OnEvent", function()
			E:Print(format("|cff00ff00queued|r %s %s", tostring(arg1), tostring(arg2)))
		end)
	end

	if not queueHooked then
		queueHooked = true
		hooksecurefunc("CastSpellByName", function(spell) LogCastAttempt(tostring(spell)) end)
		hooksecurefunc("UseAction", function(slot) LogCastAttempt("action "..tostring(slot)) end)
	end

	--pcall: registering an event this client has never heard of raises, and that is
	--itself the answer -- it means nampower never added its custom event codes
	local ok = pcall(queueWatcher.RegisterEvent, queueWatcher, "SPELL_QUEUE_EVENT")
	if not ok then
		E:Print("|cffff0000SPELL_QUEUE_EVENT is not a known event|r - nampower did not register its custom events in this session.")
		return
	end

	queueWatching = true
	E:Print("Queue watch |cff00ff00on|r - every press now prints how much of the current cast was left, and a queued press prints a second line. Compare the two against the windows above. Run /octoui-queue again to stop.")
end

--Damage meter totals, before there is any window to read them in. `overall` unless
--"current" is passed, so a fight can be checked against a whole session.
--Guarded because MailTools.lua is a new file and 1.12 indexes the AddOns folder at
--process start, so after a /reload this file is current while that one may not exist yet.
function E:MailReport()
	local Misc = E:GetModule("Misc", true)
	if not (Misc and Misc.MailReport) then
		E:Print("|cffff0000Mail tools are not loaded.|r")
		return
	end

	Misc:MailReport()
end

--Bare command opens the browser; with an argument it prints the first matching
--recipe's sources to chat, which is the only way to get at them while a
--full-screen window would be in the way.
--Which group members are broadcasting a spec, and what role it resolved to. The
--spec-texture table cannot be verified from outside the game, so an unmapped spec
--has to be visible somewhere rather than just drawing no icon.
function E:SpecRoleReport()
	local UF = E:GetModule("UnitFrames", true)
	if not (UF and UF.SpecRoleReport) then
		E:Print("|cffff0000Role icons are not loaded.|r")
		return
	end

	UF:SpecRoleReport()
end

--Bare command toggles the window; "status" says why it will not open, which is
--almost always that aux is loaded and owns the auction house.
function E:AuctionCommand(msg)
	local A = E:GetModule("Auction", true)
	if not (A and A.Command) then
		E:Print("|cffff0000The auction house module is not loaded.|r")
		return
	end

	A:Command(msg and string.lower(msg) or "")
end

function E:RecipeFinderCommand(msg)
	local RF = E:GetModule("RecipeFinder", true)
	if not (RF and RF.Command) then
		E:Print("|cffff0000Recipe Finder is not loaded.|r")
		return
	end

	RF:Command(msg)
end

function E:MeterReport(msg)
	local M = E:GetModule("Misc", true)
	if not (M and M.MeterData) then
		E:Print("|cffff0000Damage meter is not loaded.|r")
		return
	end

	--Which of the two sources is running, and for the fallback how much of the combat
	--log this client actually handed over. A fallback with no format strings behind it
	--is a window that will stay empty forever, and that has to be visible rather than
	--looking like nothing is happening.
	local source, patterns, events = M:MeterSource()
	if source == "combatlog" then
		E:Print(format("|cffff9900combat log fallback|r - nampower's events are not on this client, so the meter is reading the log instead: %d format strings, %d events. Less accurate, and capped by the log's own range.", patterns or 0, events or 0))
	end

	if not M.MeterAvailable() then
		E:Print("|cffff0000No usable source.|r nampower's combat events are not available, and this client did not provide the combat log format strings to fall back on either.")
		return
	end

	if msg and lower(msg) == "reset" then
		M:ResetMeter()
		E:Print("Meter reset.")
		return
	elseif msg and lower(msg) == "debug" then
		E:Print(format("Meter event dump %s.", M:ToggleMeterDebug() and "|cff00ff00on|r - every damage event in range now prints its raw arguments" or "|cffff9900off|r"))
		return
	end

	local segment = (msg and lower(msg) == "current") and "current" or "overall"
	local rows, duration = M:MeterData(segment)

	E:Print(format("%s -- %.1fs, %d sources", segment, duration, getn(rows)))

	--The banked fights, so the window's segment button is not the only way to know
	--what is in there
	local past = M:MeterHistory()
	if getn(past) > 0 then
		local line = ""
		for i = 1, getn(past) do
			line = line..format("%s%s (%.0fs)", (i > 1) and ", " or "", past[i].label, past[i].duration)
		end
		E:Print(format("%d banked: %s", getn(past), line))
	end

	if getn(rows) == 0 then
		E:Print("nothing recorded yet")
		return
	end

	for i = 1, getn(rows) do
		local row = rows[i]
		if row.damage > 0 or row.healing > 0 then
			E:Print(format("%d. %s  %d dmg (%.1f dps)%s", i, row.name, row.damage, row.dps,
				row.healing > 0 and format("  %d heal (%.1f hps)", row.healing, row.hps) or ""))

			--Per-spell breakdown, which until now was recorded and never shown anywhere.
			--The window has a click-through view of the same data; this is the version
			--that can be pasted into a chat window.
			local spells = M:MeterSpells(segment, row.guid, "damage")
			for s = 1, getn(spells) do
				local hits = spells[s].hits
				E:Print(format("      |cff999999%s  %d  %.0f%%  %d %s|r",
					spells[s].name, spells[s].damage, spells[s].share * 100,
					hits, (hits == 1) and "hit" or "hits"))
			end
		end
	end
end

--Locally modelled threat on the current target, for when the server will not answer --
--which on this server is any time you are not in a group. Prints the confidence
--alongside, because a fight carried by Torment's unverified flat value deserves less
--trust than one that was all plain damage, and the number alone cannot say which.
function E:ThreatModelReport(msg)
	local M = E:GetModule("Misc", true)
	if not (M and M.ThreatOn) then
		E:Print("|cffff0000Threat model is not loaded.|r A newly added file needs a full exit of WoW.exe, not a reload.")
		return
	end

	if not M:ThreatModelAvailable() then
		E:Print("|cffff0000nampower is not in this session|r - the model reads its structured combat events, so it has nothing to work from.")
		return
	end

	local rows, top = M:ThreatOn()
	if getn(rows) == 0 then
		E:Print("no threat recorded on the current target yet")
		return
	end

	local confidence = M:ThreatConfidence()
	E:Print(format("threat on %s -- %d source(s), %.0f%% from checked numbers",
		UnitName("target") or "?", getn(rows), confidence * 100))

	if confidence < 1 then
		E:Print("|cffff9900Some of this leans on ability threat values that have not been verified on this server.|r See ABILITY_THREAT in Modules/Misc/ThreatModel.lua.")
	end

	for i = 1, getn(rows) do
		local row = rows[i]
		E:Print(format("%d. %s  %.0f  |cff999999%.0f%%|r", i, row.name, row.threat, row.share * 100))

		--What that number was built from, read at the same instant as the number itself.
		--Comparing this against the damage meter cannot work -- the two are read seconds
		--apart with a fight still running, so a discrepancy is equally explained by the
		--model being wrong or by you having killed more things in between. Shown inline,
		--a single reading checks itself: for a warlock, with no stance and no modelled
		--talents, the ratio should sit at 1.0 and anything else is a real finding.
		--The ratio measures how damage and healing were converted into threat, so the
		--flat component comes out of the numerator first. Left in, it reads as an error
		--on precisely the actors that carry flat threat -- a Voidwalker showed 1.94 when
		--its damage conversion was in fact exactly 1.00, and the whole 0.94 was Torment
		--working as designed. Flat is printed beside it because it is the guessed part
		--and deserves to be looked at, not because it belongs in the ratio.
		local base = row.damage + (row.healing * 0.5)
		E:Print(format("      |cff999999from %.0f dmg + %.0f heal + %.0f flat -- ratio %.2f|r",
			row.damage, row.healing, row.flat,
			(base > 0) and ((row.threat - row.flat) / base) or 0))
	end
end

--Delegates: the interesting state is all locals of Modules/Bags/Sort.lua.
--`msg` is forwarded so `/octoui-bags moves` can ask for the per-move verdicts.
function E:BagSortReport(msg)
	local B = E:GetModule("Bags", true)
	if B and B.SortReport then
		B:SortReport(msg)
	else
		E:Print("|cffff0000Bags module is not loaded.|r")
	end
end

--Why the threat window is not on screen. Every one of these has been a real cause
--at least once: the module never initialised, the frame is hidden, it is parked off
--screen by the saved position, it is scaled or faded to nothing, or it is sized to
--zero height. Reports all of them at once rather than one reload per guess.
function E:ThreatReport(msg)
	--Short form first: the long report cannot reliably be copied out of the game.
	if msg and lower(msg) == "model" then
		E:ThreatModelReport()
		return
	end
	local frame = _G["OctoTWTMain"]

	E:Print(format("module: %s, private toggle: %s, standalone TWThreat: %s",
		E:GetModule("ThreatMeter", true) and "registered" or "|cffff0000MISSING|r",
		E.private.general.threatMeter and "on" or "|cffff0000off|r",
		IsAddOnLoaded("TWThreat") and "|cffff0000loaded (conflicts)|r" or "not loaded"))

	if not frame then
		E:Print("|cffff0000TWTMain does not exist|r - the XML never loaded. A newly added file needs a full exit of WoW.exe, not a reload.")
		return
	end

	E:Print(format("frame: shown %s, visible %s, alpha %.2f, strata %s, level %d",
		tostring(frame:IsShown()), tostring(frame:IsVisible()), frame:GetAlpha(),
		frame:GetFrameStrata(), frame:GetFrameLevel()))

	E:Print(format("size: %.0f x %.0f, scale %.2f (config %.2f)",
		frame:GetWidth(), frame:GetHeight(), frame:GetEffectiveScale(),
		(OctoTWT_CONFIG and OctoTWT_CONFIG.windowScale) or 0))

	--nil means the frame has never been given a position it could resolve
	local left, top = frame:GetLeft(), frame:GetTop()
	if not (left and top) then
		E:Print("position: |cffff0000unresolved|r - the frame has no usable anchor, so it is drawn nowhere.")
	else
		--both sides converted to real pixels: GetLeft is in the frame's own units and
		--GetScreenWidth is in UIParent's, and comparing the two directly is nonsense
		local scale = frame:GetEffectiveScale()
		local uiScale = E.UIParent:GetEffectiveScale()
		local pxLeft, pxTop = left * scale, top * scale
		local pxWidth = GetScreenWidth() * uiScale
		local pxHeight = GetScreenHeight() * uiScale
		local onScreen = pxTop > 0 and pxTop <= pxHeight + frame:GetHeight() * scale
			and pxLeft < pxWidth and pxLeft > -(frame:GetWidth() * scale)

		E:Print(format("position: left %.0f top %.0f px on a %.0f x %.0f px screen -- %s",
			pxLeft, pxTop, pxWidth, pxHeight,
			onScreen and "|cff00ff00on screen|r" or "|cffff0000off screen|r"))
	end

	if OctoTWT_CONFIG then
		E:Print(format("config: visible %s, hideOOC %s, showInCombat %s, bars %d, bar height %d",
			tostring(OctoTWT_CONFIG.visible), tostring(OctoTWT_CONFIG.hideOOC),
			tostring(OctoTWT_CONFIG.showInCombat), OctoTWT_CONFIG.visibleBars or 0,
			OctoTWT_CONFIG.barHeight or 0))
	else
		E:Print("|cffff0000OctoTWT_CONFIG is nil|r - saved variables never loaded.")
	end

	--An empty window has two completely different causes that look identical from the
	--outside: nobody ever asked the server, or the server was asked and said nothing.
	--Threat on this client is entirely server-side, so without these two counters there
	--is no way to tell them apart and no way to know which half to go and fix.
	local TM = E:GetModule("ThreatMeter", true)
	if TM and TM.ThreatTraffic then
		local sent, replies, last, failures = TM:ThreatTraffic()
		local verdict = ""
		if failures > 0 then
			--the client refusing the send is a third cause, and it looks exactly like
			--the other two from the outside
			verdict = format(" |cffff0000-- %d send(s) rejected by the client|r", failures)
		elseif sent == 0 then
			verdict = " |cffff0000-- never asked; nothing will ever appear|r"
		elseif replies == 0 then
			verdict = " |cffff0000-- asked, but the server has not answered|r"
		elseif last then
			verdict = format(" |cff00ff00-- last reply %.0fs ago|r", GetTime() - last)
		end

		E:Print(format("traffic: %d sent, %d received%s", sent, replies, verdict))
	end

	local solo = (GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0)
	local soloState
	if not (OctoTWT_CONFIG and OctoTWT_CONFIG.soloThreat ~= false) then
		soloState = "|cffff9900off|r"
	elseif TM and TM.SoloGaveUp and TM:SoloGaveUp() then
		soloState = "|cffff9900stopped -- this server does not answer them|r"
	else
		soloState = "|cff00ff00on|r"
	end

	E:Print(format("group: %s, solo threat requests %s", solo and "solo" or "grouped", soloState))

	E:ThreatModelReport()
end

--[[
	The local model half, on its own.

	Split out because the full report is too long to get out of the game in one piece: two
	attempts to paste it on 2026-08-07 were cut off mid-word ("bar height 2", "-- ask"),
	which is the chat or the clipboard capping the text rather than anything in the code --
	a Lua error cannot truncate inside a single Print.

	`/octoui-threat model` prints these four or five lines and nothing else, which is the
	part that actually diagnoses an empty window.
]]
function E:ThreatModelReport()
	local Misc = E:GetModule("Misc", true)
	local TWTg = _G.TWT

	if not (Misc and Misc.ThreatOn) then
		E:Print("local model: |cffff0000not loaded|r")
		return
	end

	if Misc.ThreatModelAvailable and not Misc:ThreatModelAvailable() then
		E:Print("local model: |cffff0000unavailable|r - it reads nampower's combat events and this session has none.")
		return
	end

	local rows = Misc:ThreatOn()
	local count = rows and getn(rows) or 0
	local target = UnitExists("target") and UnitName("target") or "none"

	--This is the line that matters. Zero rows is the silent bail, and it means the model
	--has nothing recorded against THIS target yet -- not that anything is broken.
	E:Print(format("local model: target %s, %s row(s)%s",
		target,
		(count > 0) and format("|cff00ff00%d|r", count) or "|cffff99000|r",
		(count == 0) and " |cff999999-- nothing recorded on this target, so the window is left alone|r" or ""))

	for i = 1, count do
		local row = rows[i]
		E:Print(format("   %d. %-16s threat %.0f  share %.0f%%", i, tostring(row.name), row.threat or 0, (row.share or 0) * 100))
	end

	--[[
		Every gate between "the model has rows" and "the window draws them".

		Added because the window was reported as intermittent -- "random as fuck" -- while
		the model demonstrably had data. Four separate conditions guard the draw in
		TWT.threatQuery's OnUpdate, and from the outside a failure of any one of them looks
		identical: an empty window. Naming which one is false turns that into a fact.

		The third is the sharp one. `if TWT.targetName == '' then ... return false end`
		returns BEFORE buildLocalThreats is reached, so a blank target name skips the local
		model entirely even though the model neither needs nor uses it.
	]]
	local function YesNo(value, goodIsTrue)
		local good = goodIsTrue and value or not value
		return (good and "|cff00ff00" or "|cffff9900")..(value and "yes" or "no").."|r"
	end

	E:Print("draw gates -- all four must pass before the window is filled:")

	--Player OR pet, matching the gate itself: a warlock whose pet pulled is not flagged.
	local playerCombat = (UnitAffectingCombat("player") or UnitAffectingCombat("pet")) and true or false
	local targetCombat = UnitExists("target") and UnitAffectingCombat("target") and true or false
	local nameSet = TWTg and TWTg.targetName and TWTg.targetName ~= "" or false
	local serverLive = TWTg and TWTg.ServerAnswering and TWTg.ServerAnswering() or false

	E:Print(format("   1. player or pet in combat %s%s", YesNo(playerCombat, true),
		(not playerCombat) and " |cff999999<- neither is flagged|r" or ""))
	E:Print(format("   2. target in combat        %s%s", YesNo(targetCombat, true),
		targetCombat and "" or " |cff999999<- this flag is unreliable for NPCs on 1.12|r"))
	E:Print(format("   3. TWT.targetName set      %s%s", YesNo(nameSet, true),
		nameSet and "" or " |cff999999<- blank returns early and SKIPS the model|r"))
	E:Print(format("   4. server silent           %s%s", YesNo(not serverLive, true),
		serverLive and " |cff999999<- a reply is suppressing the model for up to 5s|r" or ""))

	if playerCombat and targetCombat and nameSet and not serverLive then
		E:Print("   |cff00ff00all gates pass -- if the window is still empty the fault is in the drawing, not the model|r")
	else
		E:Print("   |cffff9900at least one gate is closed, which is why nothing is being drawn|r")
	end
end

--Puts the window back in the middle of the screen at a sane size, for when the saved
--position or scale has put it somewhere unreachable. /twt has no equivalent.
function E:ThreatReset()
	local frame = _G["OctoTWTMain"]
	if not frame then
		E:Print("|cffff0000TWTMain does not exist.|r")
		return
	end

	if OctoTWT_CONFIG then
		OctoTWT_CONFIG.visible = true
		OctoTWT_CONFIG.windowScale = 1
	end

	frame:SetScale(1)
	frame:SetAlpha(1)
	frame:Show()

	--the mover owns the anchor, so moving the frame alone would be undone on the next
	--reload; reset the mover when there is one and only free-hand it when there is not
	if E.CreatedMovers and E.CreatedMovers["ThreatMeterMover"] then
		E:ResetMovers(L["Threat Meter"])
		E:Print("Threat window mover reset to its default position at scale 1.")
	else
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", E.UIParent, "CENTER", 0, 0)
		E:Print("Threat window reset to the centre of the screen at scale 1.")
	end
end

--Nameplate debuff timers are reconstructed from three separate things -- the bundled
--duration table, a tooltip scan for the spell name, and combat-log timestamps -- and
--when no timer appears there is no way to tell which one failed by looking at the
--nameplate. Dumps all three for the current target.
--Every debuff on the current target, with the branch that decided whose it is.
--"Everyone's dots read as mine" has four possible causes inside GetTimeLeft and they
--are indistinguishable on screen, so this names the one that actually spoke.
local function ReportTargetProvenance(NP, lib)
	if not (lib and lib.CasterProvenance) then return end
	if not UnitExists("target") then
		E:Print("No target -- target the mob whose debuffs look wrong and run this again.")
		return
	end

	local unitname, unitlevel = UnitName("target"), UnitLevel("target")
	local _, guid = UnitExists("target")

	E:Print(format("debuffs on %s |cff888888(guid %s)|r:", tostring(unitname),
		guid and "yes" or "|cffff0000no -- name lookups only|r"))

	local any
	for index = 1, 16 do
		local texture = UnitDebuff("target", index)
		if not texture then break end
		any = true

		local name = NP.ScanAuraName and NP:ScanAuraName("target", index, true)
		local branch, why = lib:CasterProvenance(unitname, unitlevel, name, guid)
		local _, _, caster = lib:GetTimeLeft(unitname, unitlevel, name, guid)

		local verdict = (caster == "player") and "|cff00ff00MINE|r" or "|cff888888not mine|r"
		E:Print(format("  %d. %s -- %s |cffffcc00[%s]|r %s",
			index, name and name ~= "" and name or "|cffff0000<name scan failed>|r",
			verdict, tostring(branch), why or ""))
	end

	if not any then E:Print("  none") end
end

function E:DebuffTimerReport()
	local NP = E:GetModule("NamePlates")
	local lib = NP and NP.LibDebuff

	local durations = E.DebuffDurations and E.DebuffDurations["debuffs"]
	local spells = 0
	if durations then
		for _ in pairs(durations) do spells = spells + 1 end
	end

	local tracked = 0
	if lib and lib.objects then
		for _ in pairs(lib.objects) do tracked = tracked + 1 end
	end

	E:Print(format("locale %s, duration table: %s (%d spells)", GetLocale(),
		durations and "loaded" or "|cffff0000MISSING|r", spells))
	E:Print(format("LibDebuff: %s, units with tracked debuffs: %d",
		lib and "loaded" or "|cffff0000MISSING|r", tracked))

	local haste = NP and NP.LibHaste
	if haste then
		E:Print(format("haste %d%% + casting speed %d%% = %.1f%% total, scales DoTs: %s",
			E.Stats:Get("haste"), E.Stats:Get("castingSpeed"), haste:GetCastingSpeed() * 100,
			haste:ScalesDots() and "|cff00ff00yes|r" or "no (durations left unhasted)"))
	else
		E:Print("LibHaste: |cffff0000MISSING|r")
	end

	--Your own casts the duration table has no entry for. Direct-damage spells belong here and
	--mean nothing; a DoT of yours in this list is why that DoT has no timer.
	if lib and lib.untracked and getn(lib.untracked) > 0 then
		local names = ""
		for i = 1, getn(lib.untracked) do
			names = (i == 1) and lib.untracked[i] or (names..", "..lib.untracked[i])
		end
		E:Print(format("own casts with no duration entry: %s", names))
		E:Print("  (direct damage spells are expected here -- a DOT of yours in that list is the reason it has no timer)")
	end

	ReportTargetProvenance(NP, lib)

	--the keys say whether the combat log is giving names or GUIDs, which is the
	--difference between a lookup that matches and one that silently does not
	if lib and lib.objects then
		for key in pairs(lib.objects) do
			E:Print(format("  tracked key: '%s'", tostring(key)))
		end
	end

	if not UnitExists("target") then
		E:Print("no target - target something you have a debuff on and run this again")
		return
	end

	local name, level = UnitName("target"), UnitLevel("target")
	--SuperWoW returns the GUID as a second value from UnitExists
	local _, guid = UnitExists("target")
	E:Print(format("target: %s (level %s) guid %s", tostring(name), tostring(level), tostring(guid)))

	local found
	for i = 1, 16 do
		--Fourth return is SuperWoW's spell id. Printed against the id we recorded for our own
		--cast, because that pair is what decides which of two identical icons draws as yours.
		local texture, _, _, spellID = UnitDebuff("target", i)
		if not texture then break end
		found = true

		local effect = NP:ScanAuraName("target", i, true)
		local known = (durations and effect and durations[effect]) and "in table" or "|cffff0000not in table|r"
		--`local a, b = cond and f()` truncates f() to one value, so timeleft was
		--always nil here regardless of what the store held. Call it plainly.
		local duration, timeleft, caster
		if lib then
			duration, timeleft, caster = lib:GetTimeLeft(name, level, effect or "", guid)
		end

		--WHOSE IT IS, and the two records that decide it. A DoT of yours reading "theirs"
		--with a second caster on the mob is the whole of the 2026-08-12 report, and none of
		--this is visible from the icon.
		local owner = "|cffff8800not known to be yours|r"
		if caster == "player" then
			owner = "|cff44ff44yours|r"
		elseif lib and effect and lib:OwnCastLive(guid, effect) then
			owner = "|cffff3333yours but not reported so|r"
		end
		if lib and effect and lib:Contested(guid, effect) then
			owner = owner.." |cff888888(someone else cast this too)|r"
		end

		local mineID = lib and effect and lib.ownspell and lib.ownspell[guid] and lib.ownspell[guid][effect]
		if spellID or mineID then
			owner = owner..format(" |cff888888[id %s, yours %s]|r", tostring(spellID), tostring(mineID))
		end

		--built separately: a nil reaching string.format raises, and an error here
		--aborts the loop, so the remaining debuffs never get reported at all
		local timer = "|cffff0000no timer|r"
		if type(timeleft) == "number" then
			timer = format("left %.1f of %.0f", timeleft, (type(duration) == "number" and duration) or 0)
		end

		E:Print(format("  %d. %s | %s | %s | %s", i,
			effect and ("'"..effect.."'") or "|cffff0000name unresolved|r", known, timer, owner))
	end

	if not found then E:Print("  target has no debuffs") end

	--THE RAW STORE, read without going through GetTimeLeft.
	--
	--GetTimeLeft DELETES an entry the moment it has expired, so the line above can only ever
	--say "no timer" for the interesting case -- a debuff whose duration was wrong, ran out
	--early, and left the icon sitting there untimed while the real debuff was still on the
	--mob. By then there is nothing left to look at.
	--
	--This reads lib.objects directly and mutates nothing, so a duration that was recorded
	--wrong can still be seen after it has lapsed: what was stored, when it started, and
	--whether it has run out. What was STORED against what the table says it should be is the
	--whole question.
	if not (lib and lib.objects) then return end

	local now = GetTime()
	for _, key in ipairs({name, guid}) do
		local store = key and lib.objects[key]
		if store then
			E:Print(format("  raw store under '%s':", tostring(key)))

			for lvl, effects in pairs(store) do
				for effect, entry in pairs(effects) do
					if type(entry) == "table" and entry.duration then
						local age = entry.start and (now - entry.start) or -1
						local remaining = entry.start and ((entry.start + entry.duration) - now) or 0
						local expected = (durations and durations[effect])
							and lib:GetDuration(effect, nil, entry.caster == "player") or nil

						E:Print(format("    [lvl %s] '%s': stored %.1fs, started %.1fs ago, %s | table says %s | caster %s",
							tostring(lvl), tostring(effect),
							entry.duration, age,
							(remaining > 0) and format("%.1fs left", remaining) or "|cffff0000EXPIRED|r",
							expected and format("%.1fs", expected) or "?",
							tostring(entry.caster or "unknown")))
					end
				end
			end
		end
	end

	--WHAT THE NAMEPLATE ICONS ACTUALLY RESOLVED.
	--
	--The store holding a caster and an icon receiving one are different questions, and the
	--raw dump above cannot tell them apart. GetTimeLeft selects an entry by GUID or name and
	--then by level, falling back to level 0 -- so the same effect stored under two levels
	--(0 from a combat-log sighting, the real level from a cast at a target) gives the reader
	--whichever bucket its own keys happen to select. A timer that draws while the caster
	--reads unknown is that fault and nothing else.
	--
	--`border` is whether the four border textures exist at all. StyleFrame creates them
	--unconditionally, so MISSING means SetAura's colouring branch never ran and the frame
	--was built by something other than CreateAuraIcon.
	E:Print("nameplate icons:")

	if not NP.CreatedPlates then
		E:Print("  |cffff0000the NamePlates module has built no plates|r")
		return
	end

	local platesShown = 0
	for frame in pairs(NP.CreatedPlates) do
		local plate = frame.UnitFrame
		local debuffs = plate and plate.Debuffs
		if debuffs and debuffs.icons then
			local header
			for i = 1, getn(debuffs.icons) do
				local icon = debuffs.icons[i]
				if icon and icon:IsShown() then
					if not header then
						header = true
						platesShown = platesShown + 1
						E:Print(format("  plate '%s' guid %s:",
							tostring(plate.UnitName), tostring(plate.guid)))
					end

					E:Print(format("    %d. '%s' | caster %s | border %s", i,
						tostring(icon.name), tostring(icon.caster or "|cffff0000unknown|r"),
						icon.bordertop and "ok" or "|cffff0000MISSING|r"))
				end
			end
		end
	end

	if platesShown == 0 then
		E:Print("  no nameplate is showing a debuff icon right now")
	end
end

--WHY THE LOOT/COMBAT WINDOW VANISHED.
--
--Three separate faults look identical from the outside and each needs a different fix: the
--chat frame itself hidden, the panel faded out behind its toggle strip, or the frame parented
--onto the wrong panel. Guessing between them has cost several rounds, and the state is lost
--on every crash -- 1.12 writes SavedVariables only on a clean logout or reload -- so it has
--to be readable while it is happening.
function E:ChatPanelReport(msg)
	local CH = E:GetModule("Chat", true)

	--Bring both panels back, whatever state they are in. The toggle button now keeps a
	--visible edge when a panel is faded, but this is the answer that cannot itself be
	--hidden -- and a panel carrying the loot and damage log is not something to lose to a
	--misclick with no way back.
	if lower(match(msg or "", "^%s*(%S*)") or "") == "show" then
		local restored = 0

		for _, side in ipairs({"Left", "Right"}) do
			local panel = _G[side.."ChatPanel"]
			local button = _G[side.."ChatToggleButton"]

			E.db[side.."ChatPanelFaded"] = nil

			if panel then
				panel:Show()
				panel:SetAlpha(1)
				restored = restored + 1
			end
			if button then button:SetAlpha(1) end
		end

		--THE WINDOW, not just the panel it sits in. The first version of this only unfaded
		--the panels, which leaves an empty frame on screen when the chat window itself is
		--the thing that is hidden -- and that is the common case, since the client remembers
		--a closed window across sessions.
		local id = (CH and CH.RightChatWindowID) or (E.db.chat and E.db.chat.rightChatWindowID)
		local chat = id and _G[format("ChatFrame%d", id)]
		local window = "no right-hand window found"

		if chat then
			--Undocked first where it applies: a docked frame that is not the selected tab is
			--hidden again by Blizzard's own dock update, so showing it alone would not last.
			if chat.isDocked and type(FCF_UnDockFrame) == "function" then
				FCF_UnDockFrame(chat)
			end

			chat:Show()
			window = format("ChatFrame%d shown", id)
		end

		E:Print(format("Restored %d chat panel(s), %s.", restored, window))
		return
	end

	E:Print(format("chat module: %s, lockPositions %s",
		(E.private.chat.enable == true) and "enabled" or "|cffff0000disabled|r",
		tostring(E.db.chat.lockPositions)))

	--Live and saved disagreeing is the FindRightChatID search having failed this session and
	--fallen back on the remembered id, which is the fallback working as intended.
	E:Print(format("right window id: live %s, saved %s",
		tostring(CH and CH.RightChatWindowID), tostring(E.db.chat.rightChatWindowID)))

	--Set by the toggle strip at the panel's bottom corner. Once true the panel AND its own
	--toggle button sit at alpha 0, so there is nothing left on screen to click back.
	E:Print(format("panel faded: right %s, left %s",
		tostring(E.db.RightChatPanelFaded), tostring(E.db.LeftChatPanelFaded)))

	local panel = _G["RightChatPanel"]
	if panel then
		E:Print(format("RightChatPanel: shown %s, alpha %.2f",
			tostring(panel:IsShown()), panel:GetAlpha() or 0))
	else
		E:Print("RightChatPanel: |cffff0000MISSING|r")
	end

	for i = 1, (NUM_CHAT_WINDOWS or 7) do
		local chat = _G[format("ChatFrame%d", i)]
		if chat then
			local parent = chat:GetParent()
			local tabText = _G[format("ChatFrame%dTabText", i)]

			E:Print(format("  ChatFrame%d '%s': shown %s, docked %s, parent %s", i,
				(tabText and tabText:GetText()) or "?",
				tostring(chat:IsShown()), tostring(chat.isDocked),
				(parent and parent:GetName()) or "?"))
		end
	end

	E:Print("Usage: /octoui-chat [show] -- show brings both chat panels back if one has been faded out.")
end

--Aura filter lists. The options GUI has no page for these -- E:SetToFilterConfig is called
--by the Filters buttons in Config/UnitFrames.lua and defined nowhere, it did not survive
--the merge of the old config addon -- so without this there is no way to see what is in a
--list, and no way at all to undo a Shift + Right-Click blacklist short of editing
--SavedVariables while logged out.
local function ResolveFilter(name)
	local filters = E.global.unitframe.aurafilters
	if not (filters and name) then return end

	if filters[name] then return name end

	--typing the name in full, in the right case, for something with no completion is a
	--poor deal; match case-insensitively instead
	local wanted = lower(name)
	for key in pairs(filters) do
		if lower(key) == wanted then return key end
	end
end

local function FilterNames()
	local out, n = "", 0
	for key in pairs(E.global.unitframe.aurafilters) do
		out = (n == 0) and key or (out..", "..key)
		n = n + 1
	end

	return out
end

--Editing the blacklist. A slash command rather than a config page for the same reason
--/octoui-filter is one: the moment you want to add someone is the moment you have just
--been ninja looted, and that is not a moment for a three-click options tree.
function E:BlacklistCommand(msg)
	local M = E:GetModule("Misc")

	--Slashes, not pipes, in user-facing text: `|` is the chat escape character and eats
	--the character after it. See the note in E:FilterCommand.
	local action, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	action = lower(action or "")

	if not M:IgnoreAPIPresent() then
		E:Print("This client does not provide the ignore list API, so there is nothing to annotate.")
		return
	end

	if action == "" or action == "list" then
		local list = M:GetIgnoreList()
		local count = getn(list)
		if count == 0 then
			E:Print("Your ignore list is empty. /ignore <name> adds one, then: /octoui-blacklist note <name> <why>")
			return
		end

		E:Print(format("Ignore list -- %d player(s). Usage: /octoui-blacklist [note / add / remove / list] <name> <reason>", count))
		for _, entry in ipairs(list) do
			E:Print(format("  %s -- %s |cff888888(noted %s)|r",
				entry.name,
				(entry.reason and entry.reason ~= "" and entry.reason) or "no reason recorded",
				entry.added or "?"))
		end
		return
	end

	--The common case: they are already ignored, you just want to record why.
	if action == "note" then
		local name, reason = match(rest or "", "^(%S+)%s*(.-)$")
		if not name or name == "" then
			E:Print("Usage: /octoui-blacklist note <name> <reason>. The reason is the whole point -- a bare name means nothing in a month.")
			return
		end

		if reason == "" then
			M:SetBlacklistNote(name, nil)
			E:Print(format("Cleared the note on %s.", name))
		else
			local note = M:SetBlacklistNote(name, reason)
			E:Print(format("%s -- %s |cff888888(noted %s)|r", name, note.reason, note.added))
		end

		M:ScheduleBlacklistRefresh()
		M:CheckGroupForBlacklisted()
		return
	end

	if action == "add" then
		local name, reason = match(rest or "", "^(%S+)%s*(.-)$")
		if not name or name == "" then
			E:Print("Usage: /octoui-blacklist add <name> <reason>. Same as /ignore, but records why at the same time.")
			return
		end

		M:AddToIgnore(name, reason ~= "" and reason or nil)
		E:Print(format("Ignoring %s -- %s", name, (reason ~= "" and reason) or "no reason recorded"))
		M:ScheduleBlacklistRefresh()
		M:CheckGroupForBlacklisted()
		return
	end

	if action == "remove" then
		local name = match(rest or "", "^(%S+)")
		if not name or name == "" then
			E:Print("Usage: /octoui-blacklist remove <name>")
			return
		end

		--The note is kept on purpose: un-ignoring is not the same as deciding you were
		--wrong, and if they end up back on the list the history is still there.
		M:RemoveFromIgnore(name)
		E:Print(format("Removed %s from your ignore list. The note is kept.", name))
		M:ScheduleBlacklistRefresh()
		return
	end

	E:Print("Usage: /octoui-blacklist [note / add / remove / list] <name> <reason>")
end

local rollActions = {need = true, greed = true, pass = true}
local AUTOROLL_USAGE = "Usage: /octoui-roll [need / greed / pass / remove / keep / once / quiet / on / off / clear] <item link, item id or name>"

--Editing the loot roll rules. A slash command as well as the options page because the
--moment you decide you always want an item is the moment it just dropped -- and a
--shift-clicked link into the chat box is both faster and less error-prone than typing the
--name of a server item into a text field.
function E:AutoRollCommand(msg)
	local M = E:GetModule("Misc")

	--AutoRoll.lua is a new file and 1.12 indexes the AddOns folder at process start, so
	--after a /reload this file can be current while that one does not exist yet.
	if not M.AddAutoRollRule then
		E:Print("Loot roll rules are not loaded yet. Exit WoW.exe fully and start it again -- a /reload cannot pick up a file that was not there at login.")
		return
	end

	--Slashes, not pipes, in user-facing text: `|` is the chat escape character and eats
	--the character after it. See the note in E:FilterCommand.
	local action, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	action = lower(action or "")

	if action == "" or action == "list" then
		local db = M:GetAutoRollSettings()
		local list = M:GetAutoRollRules()

		E:Print(format("Loot roll rules -- %s, %d item(s). New entries roll %s and are %s.",
			db.enable and "on" or "OFF",
			getn(list),
			db.newAction,
			db.autoRemove and "removed once you win" or "kept after you win"))

		for _, rule in ipairs(list) do
			E:Print(format("  %s -- %s |cff888888(%s)|r",
				M:AutoRollLabel(rule),
				rule.action,
				rule.autoRemove and "removed once you win" or "kept"))
		end

		--The half of this that cannot be verified from the filesystem. Win detection is
		--built from whichever loot strings the client actually defines, so this says which
		--were found rather than leaving auto-remove to fail silently.
		local sources = M:GetAutoRollWinSources()
		E:Print(format("Win detection: %s.",
			getn(sources) > 0 and concat(sources, ", ") or "NONE FOUND, so auto-remove cannot fire"))
		E:Print(format("Watching: %s. ConfirmLootRoll is %s.",
			concat(M:GetAutoRollWinEvents(), ", "),
			type(ConfirmLootRoll) == "function" and "present" or "absent -- a bind-on-pickup roll will still need its popup answered by hand"))

		--Names the sound that was actually taken away. "nothing yet" after a roll that still
		--clunked means the client is making that noise itself, not Lua, and no addon can
		--reach it.
		local silenced = M:GetAutoRollSilenced()
		E:Print(format("Confirmation sound: %s, last swallowed %s.",
			db.silence and "silenced" or "left alone",
			silenced or "nothing yet"))

		E:Print(AUTOROLL_USAGE)
		return
	end

	if rollActions[action] then
		if rest == "" then
			E:Print(format("Usage: /octoui-roll %s <item link, item id or name>", action))
			return
		end

		local rule = M:AddAutoRollRule(rest, action)
		if not rule then
			E:Print("Could not read an item out of that. Shift-click the item into the chat box, or give its id.")
			return
		end

		E:Print(format("%s -- %s |cff888888(%s)|r",
			M:AutoRollLabel(rule),
			rule.action,
			rule.autoRemove and "removed once you win" or "kept"))
		M:ScheduleAutoRollRefresh()
		return
	end

	if action == "remove" or action == "delete" then
		if rest == "" then
			E:Print("Usage: /octoui-roll remove <item link, item id or name>")
			return
		end

		local rule = M:RemoveAutoRollRule(rest)
		if not rule then
			E:Print("Nothing on the list matches that. An item added by name has to be removed by name, and one added by id by id.")
			return
		end

		E:Print(format("Removed %s. Rolls for it are yours again.", M:AutoRollLabel(rule)))
		M:ScheduleAutoRollRefresh()
		return
	end

	--The reputation-item case: it drops all night and has to stay on the list.
	if action == "keep" or action == "once" then
		if rest == "" then
			E:Print(format("Usage: /octoui-roll %s <item link, item id or name>", action))
			return
		end

		local rule = M:SetAutoRollRemove(rest, action == "once")
		if not rule then
			E:Print("Nothing on the list matches that.")
			return
		end

		E:Print(format("%s -- %s", M:AutoRollLabel(rule),
			rule.autoRemove and "removed once you win it" or "kept on the list however often it drops"))
		M:ScheduleAutoRollRefresh()
		return
	end

	if action == "quiet" then
		local db = M:GetAutoRollSettings()
		if rest == "" then
			db.silence = not db.silence
		else
			db.silence = (lower(rest) == "on")
		end

		E:Print(format("The roll confirmation sound is %s.", db.silence and "silenced" or "left alone"))
		M:ScheduleAutoRollRefresh()
		return
	end

	if action == "on" or action == "off" then
		M:GetAutoRollSettings().enable = (action == "on")
		E:Print(format("Loot roll rules are %s. The list is untouched.", action == "on" and "on" or "off"))
		M:ScheduleAutoRollRefresh()
		return
	end

	if action == "clear" then
		if lower(rest) ~= "confirm" then
			E:Print("That empties the whole list. Type   /octoui-roll clear confirm   if you mean it.")
			return
		end

		local db = M:GetAutoRollSettings()
		local count = getn(M:GetAutoRollRules())
		db.rules = {}
		E:Print(format("Cleared %d loot roll rule(s).", count))
		M:ScheduleAutoRollRefresh()
		return
	end

	E:Print(AUTOROLL_USAGE)
end

--The mount gear report. Nothing here can be seen from the outside: whether the mount was
--recognised, what was displaced, and what is waiting on the end of a fight are all internal
--state, and every one of them has its own way of looking like "it did not work".
function E:MountGearReport(msg)
	local M = E:GetModule("Misc")

	if not M.GetMountGearSettings then
		E:Print("Mount gear is not loaded yet. Exit WoW.exe fully and start it again -- a /reload cannot pick up a file that was not there at login.")
		return
	end

	local action, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	action = lower(action or "")

	local db = M:GetMountGearSettings()

	if action == "on" or action == "off" then
		db.enable = (action == "on")
		--Look again straight away rather than waiting for the next aura change, which if you
		--are already mounted may not come until you get off.
		M:ResetMountGearState()
		E:Print(format("Mount gear is %s.", action == "on" and "on" or "off"))
		return
	end

	--Fight gear takes a second word: /octoui-mountgear fight trinket1 <item>.
	if action == "fight" then
		local alias, item = match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
		for _, def in ipairs(M:GetMountGearSlots()) do
			if lower(alias or "") == def.alias then
				local entry = M:SetFightGearItem(def.key, item)
				if entry then
					E:Print(format("%s when not mounted: %s", def.label, M:MountGearLabel(entry)))
				else
					E:Print(format("%s: restores whatever was displaced.", def.label))
				end
				return
			end
		end

		E:Print("Usage: /octoui-mountgear fight [trinket1 / trinket2 / boots / gloves] <item link, item id or name>")
		return
	end

	--Setting a slot by name, for when typing beats opening the options tree.
	if action ~= "" and action ~= "list" then
		for _, def in ipairs(M:GetMountGearSlots()) do
			if action == def.alias then
				local entry = M:SetMountGearItem(def.key, rest)
				if entry then
					E:Print(format("%s while mounted: %s", def.label, M:MountGearLabel(entry)))
				else
					E:Print(format("%s: left alone while mounted.", def.label))
				end
				return
			end
		end

		E:Print("Usage: /octoui-mountgear [on / off / trinket1 / trinket2 / boots / gloves] <item link, item id or name>")
		E:Print("       /octoui-mountgear fight <slot> <item> -- what to wear when the mount goes")
		return
	end

	local isMounted = M:MountGearIsMounted()

	E:Print(format("Mount gear -- %s. Mounted: %s. In combat: %s.",
		db.enable and "on" or "OFF",
		isMounted and "yes" or "no",
		UnitAffectingCombat("player") and "yes" or "no"))

	--"Mounted: no" while sitting on a mount is a different fault from everything else here,
	--and it is not this module's: the check is AutoDismount's, so its buff list is where the
	--answer is. Saying so beats leaving the reader to work out which half is broken.
	if not isMounted then
		local mounts, shifts = 0, 0
		if M.DismountScanBuffs then
			local m, s = M:DismountScanBuffs()
			mounts, shifts = getn(m or {}), getn(s or {})
		end
		E:Print(format("  mount check: %s, matched %d mount buff(s) and %d form buff(s).",
			M.DismountScanBuffs and "present" or "|cffff0000MISSING|r", mounts, shifts))
		E:Print("  if you are mounted right now and that says 0, the mount's buff wording is not recognised -- run /octoui-dismount, which lists what it can see.")
	end

	for _, def in ipairs(M:GetMountGearSlots()) do
		local entry = db.slots[def.key]
		local saved = db.saved[def.key]
		local slotID = GetInventorySlotInfo(def.key)
		local worn = GetInventoryItemLink("player", slotID)

		local fight = M.GetFightGearItem and M:GetFightGearItem(def.key)

		E:Print(format("  %s -- riding: %s |cff888888(worn: %s)|r%s",
			def.label,
			entry and M:MountGearLabel(entry) or "not set",
			worn or "empty",
			saved and format(" |cffffff00owes back: %s|r", saved.empty and "an empty slot" or (M:MountGearLabel(saved) or saved.link or "?")) or ""))

		--Printed even when unset, because "not set" is the answer to "why did the wrong
		--trinket come back" and a missing line answers nothing.
		E:Print(format("       fight: %s", fight and M:MountGearLabel(fight)
			or "|cff888888not set -- restores whatever was displaced|r"))
	end

	local results, pending = M:GetMountGearResults()
	if pending then
		E:Print(format("Waiting for combat to end, then: %s.", pending == "equip" and "put riding gear on" or "put your own gear back"))
	end

	--The last pass, whichever way it went. A swap that could not happen says why here rather
	--than nowhere.
	for _, result in ipairs(results) do
		E:Print(format("  last pass -- %s: %s%s|r",
			result.slot,
			result.ok and "|cff44ff44" or "|cffff3333",
			result.detail or "?"))
	end

	E:Print("Usage: /octoui-mountgear [on / off / trinket1 / trinket2 / boots / gloves] <item link, item id or name>")
end

--The CC watch report. Whether a spell is recognised, whether the cast was seen as yours and
--why a row went away are all invisible from the list itself.
function E:CCWatchReport(msg)
	local M = E:GetModule("Misc")

	if not M.GetCCWatch then
		E:Print("CC Watch is not loaded yet. Exit WoW.exe fully and start it again -- a /reload cannot pick up a file that was not there at login.")
		return
	end

	local action, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	action = lower(action or "")

	--Spell names are case sensitive and multi-word, so `rest` is taken exactly as typed.
	if action == "add" or action == "remove" then
		if rest == "" then
			E:Print(format("Usage: /octoui-cc %s <spell name, exactly as the game writes it>", action))
			return
		end

		if action == "add" then
			M:AddCCSpell(rest)
			E:Print(format("Watching %s. It needs a debuff duration entry too, or there is no timer to show -- /octoui-dots reports missing ones.", rest))
		else
			M:RemoveCCSpell(rest)
			E:Print(format("No longer watching %s.", rest))
		end
		return
	end

	--A row for your current target, put there by hand. Splits the two halves of "nothing
	--appears": if this shows a row then the display works and anything wrong is in what
	--reaches the cast handler, and if it does not then nothing upstream would have been
	--visible anyway. It also gives you something stationary to aim /moveui at, which a real
	--fear does not -- that row lasts exactly as long as the mob does.
	if action == "test" then
		local _, guid = UnitExists("target")
		if not guid then
			_, guid = UnitExists("player")
		end

		if not guid then
			E:Print("No GUID available. Those come from SuperWoW, and without it nothing here can work.")
			return
		end

		local ok, why = M:AddCCWatch(guid, "Fear", nil, nil, "Interface\\Icons\\Spell_Shadow_Possession")
		if ok then
			E:Print(format("Test row added for %s. It stays until you right-click it. Use /moveui if you cannot see it.", UnitName(guid) or guid))
		else
			E:Print(format("Could not add a test row: %s.", why or "?"))
		end
		return
	end

	local db = M:GetCCWatchSettings()
	local watch, lastRemoved = M:GetCCWatch()

	local _, playerGUID = UnitExists("player")
	local _, petGUID = UnitExists("pet")

	E:Print(format("CC Watch -- %s, %d row(s) max. SpellInfo is %s.",
		db.enable and "on" or "OFF",
		tonumber(db.maxRows) or 4,
		type(SpellInfo) == "function" and "present" or "|cffff0000MISSING -- nothing can be recognised|r"))
	E:Print(format("  yours: player %s, pet %s", tostring(playerGUID), tostring(petGUID)))

	--The three ways "nothing appears" can happen, told apart.
	local castEvents, ownCasts, seenCasts = M:GetCCWatchStats()
	E:Print(format("  cast events seen: %d, of them yours: %d", castEvents, ownCasts))

	if castEvents == 0 then
		E:Print("  |cffff0000UNIT_CASTEVENT has never fired.|r Nothing here can work without it -- that event is SuperWoW's, so this is a SuperWoW problem rather than an OctoUI one.")
	elseif ownCasts == 0 then
		E:Print("  |cffff0000Casts are arriving but none read as yours.|r The player GUID above is what they are compared against.")
	end

	if getn(seenCasts) > 0 then
		local recent = ""
		for i = 1, getn(seenCasts) do
			recent = (i == 1) and seenCasts[i] or (recent..", "..seenCasts[i])
		end
		E:Print(format("  your recent casts: %s", recent))
	end

	local count = 0
	for guid, entry in pairs(watch) do
		count = count + 1
		local left = entry.start + entry.duration - GetTime()
		E:Print(format("  %s on %s -- %s |cff888888(id %s, %s)|r",
			entry.spell,
			UnitName(guid) or guid,
			entry.loose and format("|cffff3333LOOSE (%s)|r%s", entry.loose,
					entry.scanned and (" |cff888888["..entry.scanned.."]|r") or "")
				or format("%.1f of %.0f left", left > 0 and left or 0, entry.duration),
			tostring(entry.spellID),
			UnitExists(guid) and "visible" or "not visible, kept"))
	end

	if count == 0 then
		E:Print("  nothing controlled right now")
	end

	if lastRemoved then
		E:Print(format("  last row removed: %s", lastRemoved))
	end

	--Built-ins and your own together, since what matters is what is actually watched.
	local names, n = "", 0
	for spell in pairs(M:GetCCSpells()) do
		if M:IsWatchedSpell(spell) then
			n = n + 1
			names = (n == 1) and spell or (names..", "..spell)
		end
	end
	for spell in pairs(db.extra) do
		if M:IsWatchedSpell(spell) then
			n = n + 1
			names = (n == 1) and (spell.."*") or (names..", "..spell.."*")
		end
	end
	E:Print(format("  watching (%d, * = added by you): %s", n, names))

	local off = ""
	for spell in pairs(db.hidden) do
		off = (off == "") and spell or (off..", "..spell)
	end
	if off ~= "" then
		E:Print(format("  switched off: %s", off))
	end

	E:Print("Usage: /octoui-cc [test / add <spell> / remove <spell>]")
end

--Lua snippets that load themselves. Adding one from chat is impractical -- a multi-line
--function does not fit a slash command -- so this lists, runs and removes, and the options
--page is where the code is pasted.
function E:LuaMacroCommand(msg)
	local M = E:GetModule("Misc")

	if not M.GetLuaMacros then
		E:Print("Lua macros are not loaded yet. Exit WoW.exe fully and start it again -- a /reload cannot pick up a file that was not there at login.")
		return
	end

	local action, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	action = lower(action or "")

	if action == "run" then
		if rest == "" then
			local ran, failed = M:RunLuaMacros()
			E:Print(format("Ran %d snippet(s), %d failed.", ran, failed))
		else
			local ok, why = M:RunLuaMacro(rest)
			E:Print(ok and format("Ran %s.", rest) or format("%s: |cffff3333%s|r", rest, why or "?"))
		end
		M:ScheduleLuaMacroRefresh()
		return
	end

	if action == "remove" or action == "delete" then
		if M:RemoveLuaMacro(rest) then
			E:Print(format("Removed %s.", rest))
			M:ScheduleLuaMacroRefresh()
		else
			E:Print(format("No snippet called %s.", rest ~= "" and rest or "?"))
		end
		return
	end

	--The file first: it is where real code lives, and "is mine loaded" is the question.
	local fns = M:GetUserMacroFunctions()
	if getn(fns) > 0 then
		E:Print(format("UserMacros.lua -- |cff44ff44%d function(s) loaded|r: %s", getn(fns), concat(fns, ", ")))
	else
		E:Print("UserMacros.lua -- |cffff8800nothing loaded from it|r (Modules\\Misc\\UserMacros.lua, then /reload)")
	end

	local list = M:GetLuaMacros()
	E:Print(format("Lua macros -- %d snippet(s), %s.", getn(list),
		M:LuaMacrosLoaded() and "loaded this session" or "|cffff3333not run yet|r"))

	for _, item in ipairs(list) do
		local entry = item.entry
		local state
		if entry.enable == false then
			state = "|cff888888off|r"
		elseif entry.error then
			--The whole point of keeping the error: a snippet that failed to compile is
			--invisible otherwise, and its functions simply do not exist.
			state = format("|cffff3333%s|r", entry.error)
		else
			state = "|cff44ff44ok|r"
		end

		E:Print(format("  %s -- %s", item.name, state))
	end

	if getn(list) == 0 then
		E:Print("  none yet. Add one at /oc - General - Lua Macros, then call it from a macro with /run YourFunction()")
	end

	E:Print("Usage: /octoui-lua [run <name> / remove <name>] -- code is pasted in the options page.")
end

function E:FilterCommand(msg)
	local filters = E.global.unitframe.aurafilters
	if not filters then
		E:Print("No aura filters are defined.")
		return
	end

	local name, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	if not name or name == "" then
		--Slashes, not pipes: `|` is the chat escape character, so "add|remove|clear" loses
		--the "r" to a |r colour reset and prints as "addemove|clear". Doubling to `||`
		--works too, but reads worse in the source than it does on screen.
		E:Print("Aura filters. Usage: /octoui-filter <filter> [add / remove / clear] [spell name]")
		for key, filter in pairs(filters) do
			local count = 0
			for _ in pairs(filter.spells or {}) do count = count + 1 end
			E:Print(format("  %s (%s) - %d spell(s)", key, filter.type or "?", count))
		end
		return
	end

	local key = ResolveFilter(name)
	if not key then
		E:Print(format("No filter called '%s'. Known: %s", name, FilterNames()))
		return
	end

	local filter = filters[key]
	filter.spells = filter.spells or {}

	local action, spell = match(rest or "", "^(%S*)%s*(.-)$")
	action = action and lower(action) or ""

	if action == "" or action == "list" then
		local count = 0
		for spellName, entry in pairs(filter.spells) do
			count = count + 1
			E:Print(format("  %s%s", spellName, entry.enable and "" or " |cff888888(disabled)|r"))
		end
		E:Print(format("%s (%s): %d spell(s)", key, filter.type or "?", count))
		return
	end

	if action == "clear" then
		local count = 0
		for _ in pairs(filter.spells) do count = count + 1 end
		filter.spells = {}
		E:Print(format("Cleared %d spell(s) from %s.", count, key))
	elseif action == "add" then
		if spell == "" then E:Print("Usage: /octoui-filter "..key.." add <spell name>") return end
		--Spell names are matched exactly against what the client reports, so they are
		--stored exactly as typed rather than normalised.
		filter.spells[spell] = {["enable"] = true, ["priority"] = 0, ["stackThreshold"] = 0}
		E:Print(format("Added '%s' to %s.", spell, key))
	elseif action == "remove" or action == "delete" then
		if spell == "" then E:Print("Usage: /octoui-filter "..key.." remove <spell name>") return end
		if filter.spells[spell] == nil then
			E:Print(format("'%s' is not in %s. /octoui-filter %s lists what is.", spell, key, key))
			return
		end
		filter.spells[spell] = nil
		E:Print(format("Removed '%s' from %s.", spell, key))
	else
		E:Print(format("Unknown action '%s'. Use add, remove, clear or list.", action))
		return
	end

	local UF = E:GetModule("UnitFrames", true)
	if UF then
		--the raid debuff element only reads its list when the headers are rebuilt
		if UF.UpdateAllHeaders then UF:UpdateAllHeaders() end
		if UF.Update_AllFrames then UF:Update_AllFrames() end
	end

	--The standalone player buff and debuff panels are a separate module and rebuild only
	--on PLAYER_AURAS_CHANGED, so without this a filter edit would not show until the next
	--time an aura happened to change.
	local A = E:GetModule("Auras", true)
	if A and A.RefreshHeaders then A:RefreshHeaders() end
end

--Why the standalone buff and debuff panels are or are not on screen. Every guess about
--this has been wrong so far: it is not the enable flag, not the MMHolder anchor and not
--the growth-direction tables. Report the frames' actual state rather than reasoning about
--what it ought to be.
local function ReportAuraHeader(label, frame)
	if not frame then
		E:Print(format("  %s: FRAME DOES NOT EXIST", label))
		return
	end

	local point, relativeTo, relativePoint, x, y = frame:GetPoint()
	local relName = relativeTo and relativeTo.GetName and relativeTo:GetName() or tostring(relativeTo)

	E:Print(format("  %s: shown=%s alpha=%.2f scale=%.2f size=%dx%d",
		label, tostring(frame:IsShown()), frame:GetAlpha() or 0, frame:GetScale() or 0,
		frame:GetWidth() or 0, frame:GetHeight() or 0))

	if point then
		E:Print(format("    anchored %s to %s %s at %d, %d", point, relName, tostring(relativePoint), x or 0, y or 0))
	else
		E:Print("    |cffff0000NO ANCHOR|r - a frame with no point never draws")
	end

	--GetLeft is nil for a frame that is hidden or not yet laid out, so a real rect here is
	--also proof the frame has actually been positioned.
	local left, bottom = frame:GetLeft(), frame:GetBottom()
	if left and bottom then
		E:Print(format("    rect left=%d bottom=%d (screen is %dx%d)",
			left, bottom, GetScreenWidth(), GetScreenHeight()))
	else
		E:Print("    |cffff0000NO RECT|r - not laid out")
	end

	local shown, total = 0, 0
	local i, button = 1
	button = _G[frame:GetName().."AuraButton"..i]
	while button do
		total = total + 1
		if button:IsShown() then shown = shown + 1 end
		i = i + 1
		button = _G[frame:GetName().."AuraButton"..i]
	end
	E:Print(format("    buttons: %d created, %d shown", total, shown))
end

function E:AuraReport()
	E:Print("Standalone buff/debuff panels:")
	E:Print(format("  private.auras.enable=%s disableBlizzard=%s  MMHolder=%s",
		tostring(E.private.auras.enable), tostring(E.private.auras.disableBlizzard),
		MMHolder and "exists" or "|cffff0000MISSING|r"))

	local A = E:GetModule("Auras", true)
	if not A then E:Print("  |cffff0000module not registered|r") return end
	if not A.db then E:Print("  |cffff0000A.db is nil - Initialize returned early or raised|r") return end

	--What the client says the player actually has, independent of any of our frames.
	local counts = {}
	local f
	for _, filter in pairs({"HELPFUL", "HARMFUL"}) do
		local n, idx = 0, 0
		while true do
			idx = GetPlayerBuff(n, filter)
			if not GetPlayerBuffTexture(idx) then break end
			n = n + 1
		end
		counts[filter] = n
	end
	E:Print(format("  client reports %d buff(s), %d debuff(s)", counts.HELPFUL, counts.HARMFUL))

	ReportAuraHeader("BuffFrame", A.BuffFrame)
	ReportAuraHeader("DebuffFrame", A.DebuffFrame)

	f = E.db.movers
	E:Print(format("  saved movers: BuffsMover=%s DebuffsMover=%s",
		(f and f.BuffsMover) or "none", (f and f.DebuffsMover) or "none"))
end

--Auto dismount fails in two ways and both are invisible from the outside: the error the
--client actually sent was not one this recognises, or it was recognised but no buff looked
--like a mount. Report both rather than guessing which.
function E:DismountReport()
	local M = E:GetModule("Misc", true)
	if not (M and M.DismountErrors) then
		E:Print("|cffff0000Auto dismount did not load.|r")
		return
	end

	local live = 0
	for _ in pairs(M.DismountErrors) do live = live + 1 end

	E:Print(format("Auto dismount: enabled=%s, %d error string(s) recognised",
		tostring(E.db.general.autoDismount), live))

	--Only true for a druid who has actually taken the talent. The Moonkin icon is shared
	--with an agility buff, so on anyone else this must stay false or that buff gets cancelled.
	E:Print(format("  moonkin icon treated as a form: %s",
		M.DismountMoonkinAdded and "yes (druid with the talent)" or "no"))

	local missing = M.DismountMissingGlobals
	if getn(missing) > 0 then
		E:Print(format("  %d global(s) this client does not define (harmless, listed for the record):", getn(missing)))
		for i = 1, getn(missing) do
			E:Print("    "..missing[i])
		end
	end

	--While mounted this is the whole answer to "why did it not cancel anything".
	local mounts, shifts = M:DismountScanBuffs()
	if getn(mounts) > 0 or getn(shifts) > 0 then
		E:Print(format("  right now: %d buff(s) look like a mount, %d like a shapeshift", getn(mounts), getn(shifts)))
	else
		E:Print("  right now: |cffffff00nothing looks like a mount or shapeshift|r (fine if you are on foot)")
	end

	if M.DismountNoBuffFound then
		E:Print("  |cffff0000An error matched but no mount buff was found.|r The mount's tooltip")
		E:Print("  wording is probably not in MOUNT_STRINGS in AutoDismount.lua.")
	end

	local unmatched = M.DismountUnmatched
	if getn(unmatched) > 0 then
		E:Print("  errors seen that were NOT recognised, newest first:")
		for i = 1, getn(unmatched) do
			E:Print(format("    |cff00ddddreached %d:|r %s", i, unmatched[i]))
		end
		E:Print("  If the one that should have dismounted you is in that list, its text is")
		E:Print("  the fix -- add the matching global to ERROR_GLOBALS in AutoDismount.lua.")
	else
		E:Print("  no unrecognised errors seen yet")
	end
end

function E:LoadCommands()
	self:RegisterChatCommand("in", "DelayScriptCall")

	--The ElvUI names (/ec, /elvui, /egrid, /estatus) are deliberately NOT registered.
	--Only the engine table, saved variables and AceConfig registry key stay "ElvUI",
	--because profiles and mover positions are keyed off them; nothing a user types is.
	self:RegisterChatCommand("oc", "ToggleConfig")
	self:RegisterChatCommand("octoui", "ToggleConfig")
	self:RegisterChatCommand("ocgrid", "Grid")
	self:RegisterChatCommand("ocstatus", "ShowStatusReport")

	self:RegisterChatCommand("bgstats", "BGStats")
	self:RegisterChatCommand("luaerror", "LuaError")
	self:RegisterChatCommand("moveui", "ToggleConfigMode")
	self:RegisterChatCommand("resetui", "ResetUI")
	self:RegisterChatCommand("enable", "EnableAddon")
	self:RegisterChatCommand("disable", "DisableAddon")
	self:RegisterChatCommand("farmmode", "FarmMode")
	self:RegisterChatCommand("enableblizzard", "EnableBlizzardAddOns")
	self:RegisterChatCommand("octoui-dots", "DebuffTimerReport")
	self:RegisterChatCommand("octoui-chat", "ChatPanelReport")
	self:RegisterChatCommand("octoui-threat", "ThreatReport")
	self:RegisterChatCommand("octoui-bags", "BagSortReport")
	self:RegisterChatCommand("octoui-queue", "QueueReport")
	self:RegisterChatCommand("octoui-dps", "MeterReport")
	self:RegisterChatCommand("octoui-threatmodel", "ThreatModelReport")
	self:RegisterChatCommand("octoui-filter", "FilterCommand")
	self:RegisterChatCommand("octoui-blacklist", "BlacklistCommand")
	self:RegisterChatCommand("octoui-roll", "AutoRollCommand")
	self:RegisterChatCommand("octoui-mountgear", "MountGearReport")
	self:RegisterChatCommand("octoui-cc", "CCWatchReport")
	self:RegisterChatCommand("octoui-lua", "LuaMacroCommand")
	self:RegisterChatCommand("octoui-auras", "AuraReport")
	self:RegisterChatCommand("octoui-dismount", "DismountReport")
	self:RegisterChatCommand("octoui-mail", "MailReport")
	self:RegisterChatCommand("octoui-recipes", "RecipeFinderCommand")
	self:RegisterChatCommand("octoui-roles", "SpecRoleReport")
	self:RegisterChatCommand("octoui-ah", "AuctionCommand")
	self:RegisterChatCommand("octoui-threatreset", "ThreatReset")

	if E:GetModule("ActionBars") and E.private.actionbar.enable then
		self:RegisterChatCommand("kb", E:GetModule("ActionBars").ActivateBindMode)
	end
end
